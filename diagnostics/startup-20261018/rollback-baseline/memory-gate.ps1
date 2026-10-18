param(
  [ValidateSet('build','emulator','capture')][string]$Kind = 'capture',
  [double]$MinimumCommitHeadroomGiB = 10,
  [double]$MinimumPhysicalAvailableGiB = 6
)
$ErrorActionPreference = 'Stop'
$memory = Get-CimInstance Win32_PerfFormattedData_PerfOS_Memory
$commitHeadroom = ([double]$memory.CommitLimit - [double]$memory.CommittedBytes) / 1GB
$physicalAvailable = [double]$memory.AvailableMBytes / 1024
$processes = Get-CimInstance Win32_Process
$emulators = @($processes | Where-Object { $_.Name -match '^qemu-system-' })
$builders = @($processes | Where-Object { $_.Name -match '^(dart|dartvm|dartaotruntime|gen_snapshot)(\.exe)?$' -or ($_.Name -match '^java(\.exe)?$' -and $_.CommandLine -match 'GradleWrapperMain') })
$reasons = @()
if ($commitHeadroom -lt $MinimumCommitHeadroomGiB) { $reasons += 'Insufficient commit headroom' }
if ($physicalAvailable -lt $MinimumPhysicalAvailableGiB) { $reasons += 'Insufficient available RAM' }
if ($Kind -in @('emulator','build') -and $emulators.Count -gt 0) { $reasons += 'An emulator is already running; do not add another emulator or build concurrently' }
if ($builders.Count -gt 0) { $reasons += 'A build or Dart compiler is already running' }
[pscustomobject]@{
  Allowed = ($reasons.Count -eq 0)
  Kind = $Kind
  CommitHeadroomGiB = [math]::Round($commitHeadroom,2)
  PhysicalAvailableGiB = [math]::Round($physicalAvailable,2)
  EmulatorCount = $emulators.Count
  Reasons = $reasons
} | ConvertTo-Json -Depth 3
if ($reasons.Count -gt 0) { exit 2 }
