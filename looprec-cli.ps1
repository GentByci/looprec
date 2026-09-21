# LoopRec, console flavour: launch it to start recording the Windows default output; launch it again (or press a key
# in its window) to stop, save WAV + MP3 and reveal the file. Settings come from config.json (defaults in core.ps1).
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\core.ps1"

$created = $false
$stopEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Global\LoopRec.Toggle', [ref]$created)
if (-not $created) { [void]$stopEvent.Set(); exit }   # second launch = stop the first one

function Fail($msg) {
    Write-Host "`n  $msg" -ForegroundColor Red; Write-Host '  Press any key to close.'
    try { [void][Console]::ReadKey($true) } catch { Start-Sleep 5 }
    exit 1
}
try { Initialize-LoopRecCore } catch { Fail $_.Exception.Message }
$cfg = Get-LoopRecConfig
New-Item -ItemType Directory -Force $cfg.outDir | Out-Null
$stamp = Get-Date -Format 'yyyy-MM-dd HH-mm-ss'
$temp = Join-Path $cfg.outDir "$stamp.recording.wav"
try { $rec = New-Object LoopRec.Recorder($temp, $cfg.device, $true) } catch { Fail "Could not start capture: $($_.Exception.InnerException.Message)$($_.Exception.Message)" }

$host.UI.RawUI.WindowTitle = 'LoopRec - recording'
$keys = try { [Console]::TreatControlCAsInput = $true; [void][Console]::KeyAvailable; [Console]::CursorVisible = $false; $true } catch { $false }
Write-Host "`n  LoopRec  capturing $($rec.DeviceName)`n  Stop: press any key here, or launch LoopRec again.`n" -ForegroundColor Cyan
$hold = 0.0
while (-not $stopEvent.WaitOne(120) -and -not $rec.Error) {
    if ($keys -and [Console]::KeyAvailable) { [void][Console]::ReadKey($true); break }
    $hold = [Math]::Max($rec.TakePeak(), $hold * 0.8)
    $db = if ($hold -gt 0) { 20 * [Math]::Log10($hold) } else { -99 }
    $bar = ('#' * [Math]::Max(0, [Math]::Min(24, [int](($db + 60) / 60 * 24)))).PadRight(24, '.')
    Write-Host ("`r  REC {0}  [{1}] {2,6:0.0} dB   " -f $rec.Elapsed.ToString('mm\:ss'), $bar, $db) -ForegroundColor Red -NoNewline
}
$rec.Stop()
if ($keys) { [Console]::CursorVisible = $true }
if ($rec.Error) { Fail "Capture stopped with an error: $($rec.Error.Message)" }
if ($rec.Bytes -lt 1) { Remove-Item $temp -ErrorAction SilentlyContinue; Fail 'Nothing came through the output device - no file saved.' }

Write-Host "`n  Saving..." -ForegroundColor DarkGray
$result = Export-LoopRecording $temp $cfg.outDir $stamp $cfg
foreach ($w in $result.Warnings) { Write-Host "  $w" -ForegroundColor Yellow }
Write-Host "`n  Saved $($rec.Elapsed.ToString('m\:ss')):" -ForegroundColor Green
foreach ($f in $result.Files) { Write-Host "    $f" }
if ($cfg.openFolder -and $result.Files) { Show-InExplorer $result.Files[0] }
Start-Sleep 2
