# Shared by LoopRec.ps1 (UI) and looprec-cli.ps1 (console). Dot-source it:  . "$PSScriptRoot\core.ps1"
# Paths go through -LiteralPath everywhere: with -Path, a [ or ] in a folder name is read as a wildcard.
$script:Root = $PSScriptRoot
$script:Lib  = Join-Path $PSScriptRoot 'lib'
$script:ConfigPath = Join-Path $PSScriptRoot 'config.json'
$script:ConfigWarning = $null

# Loads NAudio and the capture core, compiling LoopRec.cs into lib\ the first time (or when it changed). One DLL per
# edition: a PowerShell 7 build references .NET facades that Windows PowerShell (the shortcut's host) can't load.
function Initialize-LoopRecCore {
    $naudio = 'NAudio.Core.dll', 'NAudio.Wasapi.dll' | ForEach-Object { Join-Path $script:Lib $_ }
    foreach ($dll in $naudio) { if (-not (Test-Path -LiteralPath $dll)) { throw "Missing $dll - run setup.ps1 first." } }
    Add-Type -LiteralPath $naudio
    $native = Join-Path $script:Lib "LoopRec.Native.$($PSVersionTable.PSEdition).dll"
    $source = Join-Path $script:Root 'LoopRec.cs'
    if (-not (Test-Path -LiteralPath $native) -or (Get-Item -LiteralPath $native).LastWriteTime -lt (Get-Item -LiteralPath $source).LastWriteTime) {
        Add-Type -AssemblyName System.Windows.Forms
        $refs = $naudio + [System.Windows.Forms.Form].Assembly.Location + [System.Windows.Forms.Message].Assembly.Location
        # PowerShell 7 drops its default references once -ReferencedAssemblies is given: name the facades (paths to
        # System.Private.CoreLib are ignored). Windows PowerShell needs the netstandard facade to see NAudio's types.
        $refs += if ($PSVersionTable.PSEdition -eq 'Core') { 'netstandard', 'System.Runtime', 'System.Threading', 'System.Threading.Tasks', 'System.Collections', 'System.ComponentModel.Primitives', 'System.Runtime.InteropServices', 'Microsoft.Win32.Primitives' }
                 else { [System.Reflection.Assembly]::Load('netstandard, Version=2.0.0.0, Culture=neutral, PublicKeyToken=cc7b13ffcd2ddd51').Location }
        # -OutputAssembly treats [ ] as wildcards even when escaped, so build in %TEMP% and copy the finished dll over.
        $out = Join-Path ([IO.Path]::GetTempPath()) "LoopRec.Native.$([Guid]::NewGuid().ToString('N')).dll"
        try { Add-Type -LiteralPath $source -ReferencedAssemblies ($refs | Select-Object -Unique) -OutputAssembly $out -ErrorAction Stop; [IO.File]::Copy($out, $native, $true) }
        finally { Remove-Item -LiteralPath $out -ErrorAction SilentlyContinue }
    }
    Add-Type -LiteralPath $native
}

# Defaults merged with config.json. Returns a hashtable; anything wrong with the file is described in $ConfigWarning.
function Get-LoopRecConfig {
    $cfg = @{
        outDir     = Join-Path ([Environment]::GetFolderPath('MyMusic')) 'Captures'
        device     = ''            # '' = Windows default output; else an endpoint ID (what the UI saves) or part of a device name
        saveWav    = $true         # 24-bit PCM
        saveMp3    = $true         # via the MP3 encoder built into Windows
        mp3Bitrate = 320000
        openFolder = $true         # show the new file in Explorer when done
        hotkey     = 'Ctrl+Alt+R'  # system-wide start/stop while the UI is open; '' disables
    }
    $saved = $null
    if (Test-Path -LiteralPath $script:ConfigPath) {
        try { $saved = Get-Content -LiteralPath $script:ConfigPath -Raw | ConvertFrom-Json }
        catch {   # set the broken file aside, or the next settings change would overwrite the user's hand edits
            Move-Item -LiteralPath $script:ConfigPath "$script:ConfigPath.bad" -Force
            $script:ConfigWarning = 'config.json is not valid JSON, so the defaults are in use. Your file was kept as config.json.bad.'
        }
    }
    foreach ($p in $saved.PSObject.Properties) {
        if (-not $cfg.ContainsKey($p.Name) -or $null -eq $p.Value) { continue }
        # Convert, not a PowerShell cast: [bool]'false' is $true, and '256k' must be rejected rather than crash the UI later.
        try { $cfg[$p.Name] = [Convert]::ChangeType($p.Value, $cfg[$p.Name].GetType(), [Globalization.CultureInfo]::InvariantCulture) }
        catch { $script:ConfigWarning = "config.json: $($p.Name) = '$($p.Value)' is not valid, so $($cfg[$p.Name]) is used." }
    }
    if (-not $cfg.saveWav -and -not $cfg.saveMp3) { $cfg.saveWav = $true }
    $cfg
}

function Save-LoopRecConfig([hashtable]$cfg) { $cfg | ConvertTo-Json | Set-Content -LiteralPath $script:ConfigPath -Encoding UTF8 }

# Temp file for a new take in $Dir: "<start time>.recording.wav", made absolute so PowerShell and .NET agree on a relative
# folder, and numbered " (2)", " (3)"... rather than overwrite an earlier take from the same second (or a repeated DST hour).
function New-LoopRecTempPath([string]$Dir) {
    $base = Join-Path $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Dir) (Get-Date -Format 'yyyy-MM-dd HH-mm-ss')
    $stem = $base
    for ($n = 2; @('.wav', '.mp3', '.recording.wav' | Where-Object { Test-Path -LiteralPath "$stem$_" }).Count; $n++) { $stem = "$base ($n)" }
    "$stem.recording.wav"
}

# '00:42', '59:59', then '1:05:00'. TimeSpan's 'mm' alone wraps back to 00 every hour.
function Format-LoopRecTime([TimeSpan]$Time) {
    if ($Time.TotalHours -ge 1) { '{0}:{1}' -f [Math]::Floor($Time.TotalHours), $Time.ToString('mm\:ss') } else { $Time.ToString('mm\:ss') }
}

# The message that matters: PowerShell wraps .NET errors ("Exception calling .ctor ..."), tasks wrap them again.
function Get-InnermostMessage([Exception]$e) { while ($e.InnerException) { $e = $e.InnerException }; $e.Message }

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
