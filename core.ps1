# Shared by LoopRec.ps1 (UI) and looprec-cli.ps1 (console). Dot-source it:  . "$PSScriptRoot\core.ps1"
$script:Root = $PSScriptRoot
$script:Lib  = Join-Path $PSScriptRoot 'lib'
$script:ConfigPath = Join-Path $PSScriptRoot 'config.json'

# Loads NAudio and the capture core, compiling LoopRec.cs into lib\ the first time (or when it changed).
function Initialize-LoopRecCore {
    $naudio = 'NAudio.Core.dll', 'NAudio.Wasapi.dll' | ForEach-Object { Join-Path $script:Lib $_ }
    foreach ($dll in $naudio) { if (-not (Test-Path $dll)) { throw "Missing $dll - run setup.ps1 first." } }
    Add-Type -Path $naudio
    $native = Join-Path $script:Lib 'LoopRec.Native.dll'
    $source = Join-Path $script:Root 'LoopRec.cs'
    if (-not (Test-Path $native) -or (Get-Item $native).LastWriteTime -lt (Get-Item $source).LastWriteTime) {
        Add-Type -AssemblyName System.Windows.Forms
        $refs = $naudio + [System.Windows.Forms.Form].Assembly.Location + [System.Windows.Forms.Message].Assembly.Location
        # PowerShell 7 drops its default references once -ReferencedAssemblies is given: name the facades (paths to
        # System.Private.CoreLib are ignored). Windows PowerShell needs the netstandard facade to see NAudio's types.
        $refs += if ($PSVersionTable.PSEdition -eq 'Core') { 'netstandard', 'System.Runtime', 'System.Threading', 'System.Collections', 'System.ComponentModel.Primitives', 'System.Runtime.InteropServices', 'Microsoft.Win32.Primitives' }
                 else { [System.Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51').Location }
        try { Add-Type -Path $source -ReferencedAssemblies ($refs | Select-Object -Unique) -OutputAssembly $native -ErrorAction Stop }
        catch { Remove-Item $native -ErrorAction SilentlyContinue; throw }   # never leave a half-written dll behind
    }
    Add-Type -Path $native
}

# Defaults merged with config.json. Returns a hashtable.
function Get-LoopRecConfig {
    $cfg = @{
        outDir     = Join-Path ([Environment]::GetFolderPath('MyMusic')) 'Captures'
        device     = ''            # '' = Windows default output; otherwise part of a device name
        saveWav    = $true         # 24-bit PCM
        saveMp3    = $true         # via the MP3 encoder built into Windows
        mp3Bitrate = 320000
        openFolder = $true         # show the new file in Explorer when done
        hotkey     = 'Ctrl+Alt+R'  # system-wide start/stop while the UI is open; '' disables
    }
    if (Test-Path $script:ConfigPath) {
        try { foreach ($p in (Get-Content $script:ConfigPath -Raw | ConvertFrom-Json).PSObject.Properties) { if ($cfg.ContainsKey($p.Name) -and $null -ne $p.Value) { $cfg[$p.Name] = $p.Value } } } catch { }
    }
    if (-not $cfg.saveWav -and -not $cfg.saveMp3) { $cfg.saveWav = $true }
    $cfg
}

function Save-LoopRecConfig([hashtable]$cfg) { $cfg | ConvertTo-Json | Set-Content $script:ConfigPath -Encoding UTF8 }

# Turns the float temp WAV into the requested files. Returns @{ Files; Warnings }.
function Export-LoopRecording([string]$TempPath, [string]$OutDir, [string]$Stamp, [hashtable]$Config) {
    $files = @(); $warnings = @()
    if ($Config.saveWav) { $wav = Join-Path $OutDir "$Stamp.wav"; [LoopRec.Export]::ToWav24($TempPath, $wav); $files += $wav }
    if ($Config.saveMp3) {
        $mp3 = Join-Path $OutDir "$Stamp.mp3"
        try { [LoopRec.Export]::ToMp3($TempPath, $mp3, [int]$Config.mp3Bitrate); $files += $mp3 } catch { $warnings += "MP3 failed: $($_.Exception.Message)" }
    }
    Remove-Item $TempPath -ErrorAction SilentlyContinue
    @{ Files = $files; Warnings = $warnings }
}

# 'Ctrl+Alt+R' -> @{ Modifiers = 3; Vk = 0x52 } for LoopRec.Hotkey; nothing if it doesn't parse.
function ConvertTo-HotkeySpec([string]$Text) {
    $mods = @{ alt = 1; ctrl = 2; control = 2; shift = 4; win = 8; windows = 8 }; $m = 0; $vk = 0
    foreach ($part in ($Text -split '\+' | ForEach-Object { $_.Trim().ToLower() } | Where-Object { $_ })) {
        if ($mods[$part]) { $m = $m -bor $mods[$part] }
        elseif ($part -match '^[a-z0-9]$') { $vk = [int][char]$part.ToUpper() }
        elseif ($part -match '^f([1-9]|1[0-9]|2[0-4])$') { $vk = 0x6F + [int]$Matches[1] }
        else { return }
    }
    if ($vk -and $m) { @{ Modifiers = $m; Vk = $vk } }
}

function Show-InExplorer([string]$Path) { Start-Process explorer.exe -ArgumentList "/select,`"$Path`"" }
