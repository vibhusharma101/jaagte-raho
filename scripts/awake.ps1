# Session watcher for Windows.
# -Session <id>: find the Claude process that ran this hook, start a hidden watcher for it, and print
#   "ok" or "error: <reason>" once the watcher has (or hasn't) proven it can take the power request.
# -Session <id> -Watch <pid>: be the watcher. Hold the request while <base>.busy exists (unless Claude
#   has waited on your input past the grace period) or a scheduled run is due (marked by <base>.held); exit when that process exits or <base>.pid no longer names us. Windows drops the
#   request when we exit.
# -Lid: print what closing the lid does on the active power plan, plugged in and on battery.
param([string]$Session, [int]$Watch = 0, [switch]$Lid)

if ($Lid) {
  $plan = [regex]::Match((powercfg /getactivescheme), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
  if (-not $plan) { 'unknown'; exit 0 }
  $names = 'do nothing', 'sleep', 'hibernate', 'shut down'
  $idx = Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerSettingDataIndex -ErrorAction SilentlyContinue |
    Where-Object InstanceID -like "*$plan*5ca83367-6e45-459f-a27b-476b1d01c936*"   # LIDACTION
  $ac = ($idx | Where-Object InstanceID -like '*\AC\*').SettingIndexValue
  $dc = ($idx | Where-Object InstanceID -like '*\DC\*').SettingIndexValue
  if ($null -eq $ac -or $null -eq $dc) { 'unknown'; exit 0 }
  "plugged in: $($names[$ac]), on battery: $($names[$dc])"
  exit 0
}

$base = Join-Path $env:TEMP "jaagte-raho-$Session"

if (-not $Watch) {
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
  while ($p -and $p.Name -notmatch '^(claude|node)\.exe$') {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)"
  }
  if (-not $p) { 'error: Claude process not found'; exit 0 }

  $old = Get-Content "$base.pid" -ErrorAction SilentlyContinue
  if ($old -and (Get-Process -Id $old -ErrorAction SilentlyContinue)) { 'ok'; exit 0 }
  Remove-Item "$base.pid", "$base.err" -ErrorAction SilentlyContinue

  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Session', $Session, '-Watch', $p.ProcessId

  # The watcher writes .pid once it has taken and released the request, or .err if it couldn't.
  for ($i = 0; $i -lt 100; $i++) {
    if (Test-Path "$base.pid") { 'ok'; exit 0 }
    if (Test-Path "$base.err") { "error: $((Get-Content "$base.err" -Raw).Trim())"; exit 0 }
    Start-Sleep -Milliseconds 100
  }
  'error: watcher did not start within 10s'
  exit 0
}

# 1 = SystemRequired, 3 = ExecutionRequired. 0 = DisplayRequired: on by default because on
# Modern Standby laptops the screen timing out can drop the whole machine into standby.
$types = @(1, 3)
if ($env:JAAGTE_RAHO_DISPLAY -ne '0') { $types += 0 }

try {
  Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class Power {
  [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
  public struct REASON_CONTEXT {
    public uint Version;
    public uint Flags;
    [MarshalAs(UnmanagedType.LPWStr)] public string SimpleReasonString;
  }
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern IntPtr PowerCreateRequest(ref REASON_CONTEXT context);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool PowerSetRequest(IntPtr request, int type);
  [DllImport("kernel32.dll", SetLastError = true)]
  public static extern bool PowerClearRequest(IntPtr request, int type);
}
'@

  $ctx = New-Object Power+REASON_CONTEXT
  $ctx.Version = 0                                   # POWER_REQUEST_CONTEXT_VERSION
  $ctx.Flags = 1                                     # POWER_REQUEST_CONTEXT_SIMPLE_STRING
  $ctx.SimpleReasonString = 'Claude is working (jaagte-raho)'
  $req = [Power]::PowerCreateRequest([ref]$ctx)
  if ($req -eq [IntPtr](-1)) { throw "PowerCreateRequest failed, Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }

  # Self-check: take and release every request type once, so the status line tells the truth.
  foreach ($t in $types) {
    if (-not [Power]::PowerSetRequest($req, $t)) { throw "PowerSetRequest($t) failed, Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
    [void][Power]::PowerClearRequest($req, $t)
  }
} catch {
  Set-Content "$base.err" $_.Exception.Message
  exit 1
}

# A scheduled run is due: <base>.until (written by the sched hook) is still ahead, or the project has
# durable jobs in .claude/scheduled_tasks.json, which only run while a session is open.
$cwd = Get-Content "$base.cwd" -ErrorAction SilentlyContinue | Select-Object -First 1
$jobs = if ($cwd) { Join-Path $cwd '.claude\scheduled_tasks.json' }
function Test-Due {
  $until = 0L
  [void][long]::TryParse([string](Get-Content "$base.until" -ErrorAction SilentlyContinue | Select-Object -First 1), [ref]$until)
  if ($until -gt [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()) { return $true }
  [bool]($jobs -and (Test-Path $jobs) -and ((Get-Content $jobs -Raw -ErrorAction SilentlyContinue) -match '"cron"'))
}

# Claude has been waiting for your input past the grace period (see awake.sh wait). The transcript
# changing after the wait began means you answered, so the wait is over.
function Test-AsleepOk {
  $line = Get-Content "$base.wait" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $line) { return $false }
  $since, $until, $path = ([string]$line).Trim() -split ' ', 3
  $s = 0L; $u = 0L
  if (-not ([long]::TryParse($since, [ref]$s) -and [long]::TryParse($until, [ref]$u))) { return $false }
  if ($path -and (Test-Path -LiteralPath $path)) {
    $m = ([DateTimeOffset](Get-Item -LiteralPath $path).LastWriteTimeUtc).ToUnixTimeSeconds()
    if ($m -gt $s) { Remove-Item "$base.wait" -ErrorAction SilentlyContinue; return $false }
  }
  [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $u
}

Set-Content "$base.pid" $PID
$held = $false
while ((Get-Process -Id $Watch -ErrorAction SilentlyContinue) -and ((Get-Content "$base.pid" -ErrorAction SilentlyContinue) -eq "$PID")) {
  $busy = ((Test-Path "$base.busy") -and -not (Test-AsleepOk)) -or (Test-Due)
  if ($busy -and -not $held) {
    foreach ($t in $types) { [void][Power]::PowerSetRequest($req, $t) }
    Set-Content "$base.held" ''
    $held = $true
  } elseif (-not $busy -and $held) {
    foreach ($t in $types) { [void][Power]::PowerClearRequest($req, $t) }
    Remove-Item "$base.held" -ErrorAction SilentlyContinue
    $held = $false
  }
  Start-Sleep -Seconds 2
}
Remove-Item "$base.held" -ErrorAction SilentlyContinue
