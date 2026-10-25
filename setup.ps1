# One-time setup: fetch NAudio, compile the capture core, create the desktop shortcut.
#   powershell -ExecutionPolicy Bypass -File setup.ps1 [-NoShortcut]
param([switch]$NoShortcut)
$ErrorActionPreference = 'Stop'
$root = $PSScriptRoot
$lib  = Join-Path $root 'lib'
New-Item -ItemType Directory -Force $lib | Out-Null

# NAudio (MIT, https://github.com/naudio/NAudio) from NuGet: only the two assemblies we use.
$tmp = Join-Path ([IO.Path]::GetTempPath()) "looprec-setup-$([Guid]::NewGuid().ToString('N').Substring(0, 8))"
foreach ($name in 'NAudio.Core', 'NAudio.Wasapi') {
    $dll = Join-Path $lib "$name.dll"
    if (Test-Path -LiteralPath $dll) { Write-Host "  $name.dll already present"; continue }
    Write-Host "  downloading $name 2.2.1..."
    New-Item -ItemType Directory -Force $tmp | Out-Null
    Invoke-WebRequest "https://www.nuget.org/api/v2/package/$name/2.2.1" -OutFile "$tmp\$name.zip"
    Expand-Archive -LiteralPath "$tmp\$name.zip" -DestinationPath "$tmp\$name" -Force
    Copy-Item -LiteralPath "$tmp\$name\lib\netstandard2.0\$name.dll" -Destination $dll
    Unblock-File -LiteralPath $dll
}
Remove-Item -LiteralPath $tmp -Recurse -Force -ErrorAction SilentlyContinue

# Compile with Windows PowerShell, the one the shortcut uses. The path is quoted for a single-quoted string: O'Brien.
$winps = "$env:SystemRoot\System32\WindowsPowerShell\v1.0\powershell.exe"
Write-Host '  compiling LoopRec.Native.Desktop.dll...'
Get-ChildItem -LiteralPath $lib -Filter 'LoopRec.Native*.dll' | Remove-Item -ErrorAction SilentlyContinue   # incl. the old single-DLL name
& $winps -NoProfile -ExecutionPolicy Bypass -Command ". '$($root -replace "'", "''")\core.ps1'; Initialize-LoopRecCore"
if ($LASTEXITCODE -ne 0 -or -not (Test-Path -LiteralPath "$lib\LoopRec.Native.Desktop.dll")) { throw 'compile failed' }

if (-not $NoShortcut) {   # no shortcut hotkey on purpose: the app registers its own (see config.json)
    $lnk = (New-Object -ComObject WScript.Shell).CreateShortcut((Join-Path ([Environment]::GetFolderPath('Desktop')) 'LoopRec.lnk'))
    $lnk.TargetPath       = $winps
    $lnk.Arguments        = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$root\LoopRec.ps1`""
    $lnk.WorkingDirectory = $root
    $lnk.IconLocation     = "$env:SystemRoot\System32\SndVol.exe,0"
    $lnk.Hotkey           = ''   # explicit: CreateShortcut keeps an existing .lnk's hotkey otherwise
    $lnk.WindowStyle      = 7    # start minimized so the console flash is barely visible
    $lnk.Description      = 'Record whatever Windows is playing'
    $lnk.Save()
    Write-Host "  shortcut: $($lnk.FullName)"
}
Write-Host 'done' -ForegroundColor Green
