# Keeps Windows awake while a Claude Code process is alive.
# No arguments: find the Claude process that ran this hook, start a hidden watcher for it, and print
#   "ok" or "error: <reason>" once the watcher has (or hasn't) taken the power request.
# -Watch <pid>: hold a power request until that process exits. Windows drops the request when we exit.
param([int]$Watch = 0)

if (-not $Watch) {
  $p = Get-CimInstance Win32_Process -Filter "ProcessId=$PID"
  while ($p -and $p.Name -notmatch '^(claude|node)\.exe$') {
    $p = Get-CimInstance Win32_Process -Filter "ProcessId=$($p.ParentProcessId)"
  }
  if (-not $p) { 'error: Claude process not found'; exit 0 }

  $base = Join-Path $env:TEMP "jaagte-raho-$($p.ProcessId)"
  if ((Test-Path "$base.pid") -and (Get-Process -Id (Get-Content "$base.pid") -ErrorAction SilentlyContinue)) { 'ok'; exit 0 }
  Remove-Item "$base.pid", "$base.err" -ErrorAction SilentlyContinue

  Start-Process powershell.exe -WindowStyle Hidden -ArgumentList `
    '-NoProfile', '-ExecutionPolicy', 'Bypass', '-File', "`"$PSCommandPath`"", '-Watch', $p.ProcessId

  # The watcher writes .pid once the request is held, or .err if it couldn't take it.
  for ($i = 0; $i -lt 100; $i++) {
    if (Test-Path "$base.pid") { 'ok'; exit 0 }
    if (Test-Path "$base.err") { "error: $((Get-Content "$base.err" -Raw).Trim())"; exit 0 }
    Start-Sleep -Milliseconds 100
  }
  'error: watcher did not start within 10s'
  exit 0
}

$base = Join-Path $env:TEMP "jaagte-raho-$Watch"
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
}
'@

  $ctx = New-Object Power+REASON_CONTEXT
  $ctx.Version = 0                                   # POWER_REQUEST_CONTEXT_VERSION
  $ctx.Flags = 1                                     # POWER_REQUEST_CONTEXT_SIMPLE_STRING
  $ctx.SimpleReasonString = 'Claude Code session running (jaagte-raho)'
  $req = [Power]::PowerCreateRequest([ref]$ctx)
  if ($req -eq [IntPtr](-1)) { throw "PowerCreateRequest failed, Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }

  # 1 = SystemRequired, 3 = ExecutionRequired. 0 = DisplayRequired: on by default because on
  # Modern Standby laptops the screen timing out can drop the whole machine into standby.
  $types = @(1, 3)
  if ($env:JAAGTE_RAHO_DISPLAY -ne '0') { $types += 0 }
  foreach ($t in $types) {
    if (-not [Power]::PowerSetRequest($req, $t)) { throw "PowerSetRequest($t) failed, Win32 error $([Runtime.InteropServices.Marshal]::GetLastWin32Error())" }
  }
} catch {
  Set-Content "$base.err" $_.Exception.Message
  exit 1
}

Set-Content "$base.pid" $PID
Wait-Process -Id $Watch -ErrorAction SilentlyContinue
Remove-Item "$base.pid" -ErrorAction SilentlyContinue
