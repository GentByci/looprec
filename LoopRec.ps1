# LoopRec - one button to record whatever Windows is playing, saved as WAV + MP3.
# While it is open, the hotkey in config.json (default Ctrl+Alt+R) and launching LoopRec again both toggle recording.
$ErrorActionPreference = 'Stop'
. "$PSScriptRoot\core.ps1"

# A second launch just pokes the running instance.
$created = $false
$toggleEvent = New-Object System.Threading.EventWaitHandle($false, 'AutoReset', 'Global\LoopRec.Toggle', [ref]$created)
if (-not $created) { [void]$toggleEvent.Set(); exit }

# WPF, not WinForms: WinForms' first System.Drawing.Font makes GDI+ enumerate every installed font (seconds, with big font libraries).
Add-Type -AssemblyName PresentationFramework, PresentationCore, WindowsBase, System.Windows.Forms

$log = Join-Path $env:TEMP 'LoopRec.log'
function Write-Log($text) { try { Add-Content $log ("{0:HH:mm:ss.fff} {1}" -f (Get-Date), $text) } catch { } }
function Show-Error($text) { Write-Log "ERROR $text"; [System.Windows.MessageBox]::Show($text, 'LoopRec', 'OK', 'Error') | Out-Null }
function Invoke-Ui([scriptblock]$action) { try { & $action } catch { Show-Error "$($_.Exception.Message)`n`n$($_.ScriptStackTrace)" } }   # errors become message boxes, not crashes

try { Initialize-LoopRecCore } catch { Show-Error $_.Exception.Message; exit 1 }
[void][LoopRec.Native]::SetProcessDPIAware()
$cfg = Get-LoopRecConfig
$S = @{ rec = $null; temp = ''; stamp = ''; hold = 0.0; last = ''; ready = $false }   # mutable state, reachable from every handler
$red = (New-Object System.Windows.Media.BrushConverter).ConvertFromString('#C81E1E')

# ---------------- window ----------------
[xml]$xaml = @"
<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" xmlns:x="http://schemas.microsoft.com/winfx/2006/xaml"
        Title="LoopRec" Width="480" SizeToContent="Height" ResizeMode="CanMinimize" WindowStartupLocation="CenterScreen"
        FontFamily="Segoe UI" FontSize="13" Background="#F6F6F6">
  <StackPanel Margin="16,16,16,12">
    <Button x:Name="RecBtn" Height="72" FontSize="24" FontWeight="Bold" Foreground="#C81E1E" Background="White" BorderBrush="#C8C8C8" Content="&#x25CF;  Record"/>
    <DockPanel Margin="0,14,0,0">
      <TextBlock Text="Source" VerticalAlignment="Center" Margin="0,0,10,0"/>
      <ComboBox x:Name="DeviceBox" Height="26" VerticalContentAlignment="Center"/>
    </DockPanel>
    <DockPanel Margin="0,10,0,0">
      <Border DockPanel.Dock="Right" Width="220" Height="14" Background="#202020" BorderBrush="#808080" BorderThickness="1">
        <Rectangle x:Name="MeterFill" HorizontalAlignment="Left" Width="0"/>
      </Border>
      <TextBlock x:Name="Status" Text="Ready" VerticalAlignment="Center"/>
    </DockPanel>
    <TextBlock Text="Save to" Margin="0,14,0,4"/>
    <DockPanel>
      <Button x:Name="BrowseBtn" DockPanel.Dock="Right" Content="Browse..." Width="84" Height="26" Margin="8,0,0,0"/>
      <TextBox x:Name="DirBox" Height="26" VerticalContentAlignment="Center"/>
    </DockPanel>
    <StackPanel Orientation="Horizontal" Margin="0,12,0,0">
      <CheckBox x:Name="WavChk" Content="WAV (24-bit)"/>
      <CheckBox x:Name="Mp3Chk" Margin="18,0,0,0"/>
      <CheckBox x:Name="OpenChk" Content="Open folder when done" Margin="18,0,0,0"/>
    </StackPanel>
    <TextBlock Margin="0,12,0,0"><Hyperlink x:Name="LastLink"><Run x:Name="LastRun"/></Hyperlink></TextBlock>
    <TextBlock x:Name="Tip" Margin="0,8,0,0" Foreground="Gray" TextWrapping="Wrap"/>
  </StackPanel>
</Window>
"@
$window = [Windows.Markup.XamlReader]::Load((New-Object System.Xml.XmlNodeReader $xaml))
foreach ($n in 'RecBtn', 'DeviceBox', 'Status', 'MeterFill', 'DirBox', 'BrowseBtn', 'WavChk', 'Mp3Chk', 'OpenChk', 'LastLink', 'LastRun', 'Tip') { Set-Variable $n $window.FindName($n) }
$hicon = [LoopRec.Native]::ExtractIcon("$env:SystemRoot\System32\SndVol.exe", 0)
if ($hicon -ne [IntPtr]::Zero) { $window.Icon = [System.Windows.Interop.Imaging]::CreateBitmapSourceFromHIcon($hicon, [System.Windows.Int32Rect]::Empty, [System.Windows.Media.Imaging.BitmapSizeOptions]::FromEmptyOptions()) }
$DirBox.Text = $cfg.outDir; $Mp3Chk.Content = "MP3 ($([int]$cfg.mp3Bitrate / 1000) kbps)"
$WavChk.IsChecked = [bool]$cfg.saveWav; $Mp3Chk.IsChecked = [bool]$cfg.saveMp3; $OpenChk.IsChecked = [bool]$cfg.openFolder

# ---------------- state ----------------
function Fill-Devices {   # after the window is on screen: enumeration takes a moment
    $enum = New-Object NAudio.CoreAudioApi.MMDeviceEnumerator
    try { $default = $enum.GetDefaultAudioEndpoint('Render', 'Multimedia').FriendlyName } catch { $default = 'none' }
    [void]$DeviceBox.Items.Add("Default output: $default")
    $DeviceBox.SelectedIndex = 0
    foreach ($d in $enum.EnumerateAudioEndPoints('Render', 'Active')) {
        $i = $DeviceBox.Items.Add($d.FriendlyName)
        if ($cfg.device -and $DeviceBox.SelectedIndex -eq 0 -and $d.FriendlyName -like "*$($cfg.device)*") { $DeviceBox.SelectedIndex = $i }
    }
    $S.ready = $true
}

function Save-Settings {
    $cfg.outDir = $DirBox.Text.Trim()
    if ($S.ready) { $cfg.device = if ($DeviceBox.SelectedIndex -le 0) { '' } else { [string]$DeviceBox.SelectedItem } }
    $cfg.saveWav = [bool]$WavChk.IsChecked; $cfg.saveMp3 = [bool]$Mp3Chk.IsChecked; $cfg.openFolder = [bool]$OpenChk.IsChecked
    Save-LoopRecConfig $cfg
}

function Set-Recording([bool]$on) {
    $RecBtn.Content = if ($on) { [string][char]0x25A0 + '  Stop' } else { [string][char]0x25CF + '  Record' }
    $RecBtn.Foreground = if ($on) { [System.Windows.Media.Brushes]::Black } else { $red }
    $window.Title = if ($on) { 'LoopRec - recording' } else { 'LoopRec' }
    $DeviceBox.IsEnabled = $BrowseBtn.IsEnabled = $DirBox.IsEnabled = -not $on
}

function Start-Rec {
    $dir = $DirBox.Text.Trim()
    if (-not $dir) { Show-Error 'Pick a folder to save into first.'; return }
    try { New-Item -ItemType Directory -Force $dir | Out-Null } catch { Show-Error "Can't create the folder:`n$dir"; return }
    Save-Settings
    $S.stamp = Get-Date -Format 'yyyy-MM-dd HH-mm-ss'
    $S.temp = Join-Path $dir "$($S.stamp).recording.wav"
    Write-Log "start -> $($S.temp)"
    try { $S.rec = New-Object LoopRec.Recorder($S.temp, $cfg.device, $true) }
    catch {
        $why = if ($_.Exception.InnerException) { $_.Exception.InnerException.Message } else { $_.Exception.Message }
        Show-Error "Could not start capturing:`n$why`n`nSome USB DACs refuse loopback - try another Source."; return
    }
    $S.hold = 0.0; $Status.Text = 'REC 00:00'
    Set-Recording $true
}

function Stop-Rec {
    $r = $S.rec; $S.rec = $null
    Write-Log 'stop'
    $r.Stop()
    Set-Recording $false
    $S.hold = 0.0; $MeterFill.Width = 0
    if ($r.Error -or $r.Bytes -lt 1) {
        Remove-Item $S.temp -ErrorAction SilentlyContinue
        $Status.Text = if ($r.Error) { 'Ready' } else { 'Nothing came through - not saved' }
        if ($r.Error) { Show-Error "Capture stopped:`n$($r.Error.Message)" }
        return
    }
    $Status.Text = 'Saving...'; $RecBtn.IsEnabled = $false
    $window.Dispatcher.Invoke([Action]{}, [System.Windows.Threading.DispatcherPriority]::Render)   # repaint before the encode blocks
    try { $result = Export-LoopRecording $S.temp $DirBox.Text.Trim() $S.stamp $cfg }
    catch { $Status.Text = 'Ready'; $RecBtn.IsEnabled = $true; Show-Error "Saving failed:`n$($_.Exception.Message)"; return }
    $RecBtn.IsEnabled = $true
    Write-Log "saved -> $($result.Files -join ', ')"
    $Status.Text = "Saved $($r.Elapsed.ToString('m\:ss'))" + $(if ($result.Warnings) { " ($($result.Warnings -join '; '))" })
    if ($result.Files) {
        $S.last = $result.Files[0]; $LastRun.Text = 'Last: ' + (Split-Path $S.last -Leaf)
        if ($OpenChk.IsChecked) { Show-InExplorer $S.last }
    }
}

function Toggle-Rec { if ($S.rec) { Stop-Rec } else { Start-Rec } }

# ---------------- hotkey + events ----------------
$spec = ConvertTo-HotkeySpec $cfg.hotkey
$hotkey = if ($spec) { New-Object LoopRec.Hotkey($spec.Modifiers, $spec.Vk) }
$Tip.Text = if (-not $hotkey) { 'Launching LoopRec again also starts and stops.' }
            elseif ($hotkey.Registered) { "$($cfg.hotkey) starts and stops from anywhere while LoopRec is open." }
            else { "Hotkey $($cfg.hotkey) is taken by another app - change it in config.json." }

$RecBtn.Add_Click({ Invoke-Ui { Toggle-Rec } })
$BrowseBtn.Add_Click({ Invoke-Ui {
    $picked = [LoopRec.FolderPicker]::Show((New-Object System.Windows.Interop.WindowInteropHelper $window).Handle, 'Where should recordings go?', $DirBox.Text.Trim())
    if ($picked) { $DirBox.Text = $picked; Save-Settings }
} })
$DirBox.Add_LostFocus({ if ($DirBox.Text.Trim()) { Invoke-Ui { Save-Settings } } })
$DeviceBox.Add_SelectionChanged({ if ($S.ready) { Invoke-Ui { Save-Settings } } })
foreach ($chk in $WavChk, $Mp3Chk, $OpenChk) { $chk.Add_Click({ Invoke-Ui { if (-not $WavChk.IsChecked -and -not $Mp3Chk.IsChecked) { $this.IsChecked = $true }; Save-Settings } }) }
$LastLink.Add_Click({ if ($S.last -and (Test-Path $S.last)) { Show-InExplorer $S.last } })

$timer = New-Object System.Windows.Threading.DispatcherTimer -Property @{ Interval = [TimeSpan]::FromMilliseconds(100) }
$timer.Add_Tick({
    $poked = $toggleEvent.WaitOne(0)
    if ($hotkey -and $hotkey.TakePress()) { $poked = $true }
    if ($poked) {
        Write-Log 'toggle'
        if ($window.WindowState -eq 'Minimized') { $window.WindowState = 'Normal' }
        [void]$window.Activate()
        Invoke-Ui { Toggle-Rec }
    }
    if (-not $S.rec) { return }
    if ($S.rec.Error) { Invoke-Ui { Stop-Rec }; return }
    $S.hold = [Math]::Max($S.rec.TakePeak(), $S.hold * 0.8)
    $Status.Text = 'REC ' + $S.rec.Elapsed.ToString('mm\:ss')
    $db = if ($S.hold -gt 0) { 20 * [Math]::Log10($S.hold) } else { -99 }
    $MeterFill.Width = [Math]::Max(0.0, $MeterFill.Parent.ActualWidth - 2) * [Math]::Max(0.0, [Math]::Min(1.0, ($db + 60) / 60))
    $MeterFill.Fill = if ($db -gt -3) { [System.Windows.Media.Brushes]::OrangeRed } elseif ($db -gt -12) { [System.Windows.Media.Brushes]::Gold } else { [System.Windows.Media.Brushes]::LimeGreen }
})

$window.Add_ContentRendered({ Invoke-Ui { Fill-Devices }; $timer.Start(); [void]$RecBtn.Focus() })
$window.Add_Closing({ $timer.Stop(); if ($S.rec) { Invoke-Ui { Stop-Rec } }; if ($hotkey) { $hotkey.Dispose() }; $toggleEvent.Dispose(); Write-Log 'closed' })
[void]$window.ShowDialog()
