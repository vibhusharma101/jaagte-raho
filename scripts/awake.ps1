# Session watcher for Windows.
# -Session <id>: find the Claude process that ran this hook, start a hidden watcher for it, and print
#   "ok" or "error: <reason>" once the watcher has (or hasn't) proven it can take the power request.
# -Session <id> -Watch <pid>: be the watcher. Hold the request while <base>.busy exists (unless Claude
#   has waited on your input past the grace period) or a scheduled run is due (marked by <base>.held); exit when that process exits or <base>.pid no longer names us. Windows drops the
#   request when we exit.
# -Lid: print what closing the lid does on the active power plan, plugged in and on battery.
# -RestoreLid: put the lid setting back if the lid override changed it and no session needs it now.
# -LidFlag <path>: the file /jaagte-raho:lid on creates; the watcher checks it on every loop.
param([string]$Session, [int]$Watch = 0, [switch]$Lid, [switch]$RestoreLid, [string]$LidFlag)

# --- Lid override (opt-in via /jaagte-raho:lid on) ---
# While a session holds the lock, closing the lid does nothing. Only the plugged-in (AC) value of
# the lid setting changes, so on battery closing the lid still sleeps the machine. The lid setting is
# one value for the whole machine, shared by every session: the value found is saved once in
# lid.orig ("<plan guid> <value>"), next to the switch file rather than in Temp, so disk cleanup
# can't delete it while the setting is changed. Each session that needs the override marks
# <base>.lid, and whoever lets go last puts the saved value back. A watcher that finds a saved value
# with no live session behind it (after a crash or reboot) also puts it back, as does
# /jaagte-raho:lid off. Changes happen under a mutex, so two sessions never save each other's value.
$lidGuid = '5ca83367-6e45-459f-a27b-476b1d01c936'   # LIDACTION
$lidNames = 'do nothing', 'sleep', 'hibernate', 'shut down'
if (-not $LidFlag) { $LidFlag = Join-Path $HOME '.config\jaagte-raho\lid' }
$orig = Join-Path (Split-Path $LidFlag) 'lid.orig'

function Get-ActiveScheme {
  [regex]::Match((powercfg /getactivescheme), '[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}').Value
}

function Get-LidIndex($scheme, $acdc) {   # $acdc: AC or DC
  (Get-CimInstance -Namespace root\cimv2\power -ClassName Win32_PowerSettingDataIndex -ErrorAction SilentlyContinue |
    Where-Object InstanceID -like "*$scheme*\$acdc\*$lidGuid*").SettingIndexValue
}

function Set-LidAc($scheme, $value) {
  powercfg /setacvalueindex $scheme SUB_BUTTONS LIDACTION $value | Out-Null
  if ($LASTEXITCODE) { throw "powercfg /setacvalueindex failed with exit code $LASTEXITCODE" }
  powercfg /setactive SCHEME_CURRENT | Out-Null
}

function Test-LidHolders {   # another live session has the override on
  foreach ($f in Get-ChildItem $env:TEMP -Filter 'jaagte-raho-*.lid' -ErrorAction SilentlyContinue) {
    if ($base -and $f.FullName -eq "$base.lid") { continue }
    $p = Get-Content ($f.FullName -replace '\.lid$', '.pid') -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($p -and (Get-Process -Id $p -ErrorAction SilentlyContinue)) { return $true }
    Remove-Item $f.FullName -ErrorAction SilentlyContinue   # left by a watcher that's gone
  }
  $false
}

function Invoke-LidLocked([scriptblock]$body) {
  $mtx = New-Object Threading.Mutex($false, 'Local\jaagte-raho-lid')
  try { [void]$mtx.WaitOne(10000) } catch [Threading.AbandonedMutexException] { }   # owner died; it's ours now
  try { & $body } finally { $mtx.ReleaseMutex(); $mtx.Dispose() }
}

function Restore-LidIfUnused {   # call under the mutex
  if (-not (Test-Path $orig) -or (Test-LidHolders)) { return }
  $scheme, $value = ([string](Get-Content $orig | Select-Object -First 1)).Trim() -split ' '
  if ($scheme -match '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$' -and $value -match '^[0-3]$') {
    Set-LidAc $scheme $value
  }
  Remove-Item $orig -ErrorAction SilentlyContinue
}

if ($Lid) {
  $plan = Get-ActiveScheme
  if (-not $plan) { 'unknown'; exit 0 }
  $ac = Get-LidIndex $plan AC
  $dc = Get-LidIndex $plan DC
  if ($null -eq $ac -or $null -eq $dc) { 'unknown'; exit 0 }
  "plugged in: $($lidNames[$ac]), on battery: $($lidNames[$dc])"
  if (Test-Path $orig) {
    $value = ([string](Get-Content $orig | Select-Object -First 1)).Trim() -split ' ' | Select-Object -Last 1
    if ($value -match '^[0-3]$') { "lid override: on, puts plugged in back to '$($lidNames[$value])' once Claude is done" }
  }
  exit 0
}

if ($RestoreLid) {
  try { Invoke-LidLocked { Restore-LidIfUnused }; 'ok' } catch { "error: $($_.Exception.Message)" }
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

  $argv = '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Session', $Session, '-Watch', $p.ProcessId
  if ($LidFlag) { $argv += '-LidFlag', "`"$LidFlag`"" }
  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList $argv

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

# Claude has been waiting for your input past the grace period (see awake.sh wait). The transcript,
# or a subagent's (<session>\subagents\*.jsonl), changing after the wait began means you answered.
function Test-AsleepOk {
  $line = Get-Content "$base.wait" -ErrorAction SilentlyContinue | Select-Object -First 1
  if (-not $line) { return $false }
  $since, $until, $path = ([string]$line).Trim() -split ' ', 3
  $s = 0L; $u = 0L
  if (-not ([long]::TryParse($since, [ref]$s) -and [long]::TryParse($until, [ref]$u))) { return $false }
  if ($path) {
    $files = @(Get-Item -LiteralPath $path -ErrorAction SilentlyContinue) +
      @(Get-ChildItem -LiteralPath (Join-Path ($path -replace '\.jsonl$', '') 'subagents') -Filter *.jsonl -ErrorAction SilentlyContinue)
    foreach ($f in $files) {
      if (([DateTimeOffset]$f.LastWriteTimeUtc).ToUnixTimeSeconds() -gt $s) {
        Remove-Item "$base.wait" -ErrorAction SilentlyContinue; return $false
      }
    }
  }
  [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() -ge $u
}

# Turn this session's lid override on or off, saving or restoring the machine's value as needed.
# A failure is written to <base>.lid.err (shown by status) and not retried until the switch changes.
$lidFailed = $false
function Update-Lid([bool]$want) {
  if (-not $want) { $script:lidFailed = $false }
  $mine = Test-Path "$base.lid"
  if ($want -and ($mine -or $lidFailed)) { return }
  if (-not $want -and -not $mine -and -not (Test-Path $orig)) { return }
  try {
    Invoke-LidLocked {
      if ($want) {
        if (-not (Test-Path $orig)) {
          $scheme = Get-ActiveScheme
          $value = if ($scheme) { Get-LidIndex $scheme AC }
          if ($null -eq $value) { throw 'could not read the lid setting of the active power plan' }
          Set-Content $orig "$scheme $value"
          if ($value -ne 0) { Set-LidAc $scheme 0 }
        }
        Set-Content "$base.lid" ''
      } else {
        Remove-Item "$base.lid" -ErrorAction SilentlyContinue
        Restore-LidIfUnused
      }
    }
    Remove-Item "$base.lid.err" -ErrorAction SilentlyContinue
  } catch {
    Set-Content "$base.lid.err" "lid override: $($_.Exception.Message)"
    if ($want) { $script:lidFailed = $true }
  }
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
  Update-Lid ($held -and $LidFlag -and (Test-Path -LiteralPath $LidFlag))
  Start-Sleep -Seconds 2
}
Remove-Item "$base.held" -ErrorAction SilentlyContinue
Update-Lid $false
