param(
  [Parameter(Mandatory=$true)][ValidateRange(1,999)][int]$Session,
  [ValidateRange(1536,4096)][int]$MemoryMiB = 2560,
  [switch]$ObservePrelaunch
)
$ErrorActionPreference = 'Stop'
$repo = (Resolve-Path (Join-Path $PSScriptRoot '..')).Path
$logs = Join-Path $repo 'diagnostics\startup-20261030\parallel-audio'
$stem = Join-Path $logs "emulator$Session"
foreach ($suffix in @('-gate.json','-launch.json','-stable.out.log','-stable.err.log')) {
  if (Test-Path -LiteralPath ($stem + $suffix)) { throw "Session files already exist: $Session" }
}
if ($ObservePrelaunch) {
  [pscustomobject]@{mode='observe'; note='Launch outcome is checked from the actual emulator process and stderr.'} |
    ConvertTo-Json | Set-Content -LiteralPath ($stem + '-gate.json') -Encoding utf8
} else {
  $gate = Join-Path $repo 'diagnostics\startup-20261018\rollback-baseline\memory-gate.ps1'
  & powershell -NoProfile -File $gate -Kind emulator -MinimumPhysicalAvailableGiB 10 > ($stem + '-gate.json')
  if ($LASTEXITCODE -ne 0) { Get-Content -LiteralPath ($stem + '-gate.json'); exit $LASTEXITCODE }
}
$runtime = (Resolve-Path (Join-Path $repo 'tmp\startup-test-emulator-37.2.12\emulator')).Path
$env:ANDROID_AVD_HOME = 'D:\Android\.android\avd'
$env:ANDROID_SDK_ROOT = 'D:\Android_studio_sdk'
$env:PATH = "$runtime;$runtime\lib64;$env:PATH"
$parameters = @('-avd','PiliPlusStartupIsolated_20261018','-port','5554',
  '-memory',"$MemoryMiB",'-no-window','-no-snapshot','-no-boot-anim','-gpu','host','-feature','-Vulkan','-show-kernel')
$launcher = Start-Process -FilePath (Join-Path $runtime 'emulator.exe') -ArgumentList $parameters `
  -WorkingDirectory $runtime -WindowStyle Hidden -PassThru `
  -RedirectStandardOutput ($stem + '-stable.out.log') -RedirectStandardError ($stem + '-stable.err.log')
$record = [pscustomobject]@{launcherPid=$launcher.Id; startTime=$launcher.StartTime; runtime=$runtime; arguments=$parameters; observePrelaunch=[bool]$ObservePrelaunch}
$record | ConvertTo-Json -Depth 3 | Set-Content -LiteralPath ($stem + '-launch.json') -Encoding utf8
$record | ConvertTo-Json -Depth 3
Get-Content -LiteralPath ($stem + '-gate.json')
