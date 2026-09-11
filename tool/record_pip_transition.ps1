param(
    [string]$Adb = 'D:\Android_Studio_Sdk\platform-tools\adb.exe',
    [string]$Serial = 'emulator-5554',
    [string]$Package = 'com.personal.piliplus',
    [ValidateSet('Home', 'Manual')][string]$Entry = 'Home',
    [int]$ButtonX = -1,
    [int]$ButtonY = -1,
    [string]$OutputDirectory = 'diagnostics/pip-research-20260910'
)
$ErrorActionPreference = 'Stop'
function Invoke-Adb([string[]]$Arguments) {
    $result = & $Adb -s $Serial @Arguments
    if ($LASTEXITCODE -ne 0) { throw "adb failed: $Arguments" }
    return $result
}
$activity = (Invoke-Adb @('shell', 'dumpsys', 'activity', 'activities')) -join "`n"
if ($activity -match 'mode=pinned') { throw 'Already in PiP; restore the playing page before recording.' }
$window = (Invoke-Adb @('shell', 'dumpsys', 'window')) -join "`n"
if ($window -notmatch "mCurrentFocus=.*$([regex]::Escape($Package))") {
    throw 'Target app is not focused. This recording would not test PiP entry.'
}
$media = (Invoke-Adb @('shell', 'dumpsys', 'media_session')) -join "`n"
$session = [regex]::Match($media, "(?s)package=$([regex]::Escape($Package))\s.*?state=PlaybackState \{state=([^,]+)")
if (!$session.Success -or $session.Groups[1].Value -notmatch '^PLAYING\(3\)$|^3$') {
    throw 'Target video is not playing (possibly still buffering). Do not count this as a PiP transition test.'
}
if ($Entry -eq 'Manual' -and ($ButtonX -lt 0 -or $ButtonY -lt 0)) {
    throw 'Manual entry requires button coordinates from the current device screenshot.'
}
New-Item -ItemType Directory -Path $OutputDirectory -Force | Out-Null
$stamp = Get-Date -Format 'yyyyMMdd-HHmmss-fff'
$base = Join-Path $OutputDirectory "$stamp-$Entry"
$remote = "/sdcard/pip-probe-$stamp.mp4"
Invoke-Adb @('logcat', '-d', '-s', 'PiliPlusPiP:D', '*:S') | Out-File "$base-before.log" -Encoding utf8
$recorder = Start-Process -FilePath $Adb -ArgumentList @('-s', $Serial, 'shell', 'screenrecord', '--time-limit', '6', $remote) -PassThru -WindowStyle Hidden
Start-Sleep -Milliseconds 750
if ($Entry -eq 'Home') {
    Invoke-Adb @('shell', 'input', 'keyevent', 'KEYCODE_HOME') | Out-Null
} else {
    Invoke-Adb @('shell', 'input', 'tap', "$ButtonX", "$ButtonY") | Out-Null
}
$recorder.WaitForExit(12000) | Out-Null
Invoke-Adb @('pull', $remote, "$base.mp4") | Out-Null
$after = (Invoke-Adb @('shell', 'dumpsys', 'activity', 'activities')) -join "`n"
$after | Out-File "$base-activity.txt" -Encoding utf8
Invoke-Adb @('logcat', '-d', '-s', 'PiliPlusPiP:D', '*:S') | Out-File "$base-after.log" -Encoding utf8
if ($after -notmatch "Task\{[^\r\n]*$([regex]::Escape($Package))[^\r\n]*mode=pinned") {
    throw "FAIL: target app never reached PiP. Evidence: $base"
}
Write-Output "PiP entry confirmed: $base.mp4"
Write-Output 'This verifies entry only. Inspect transition frames for overlays, details UI and moving video.'
