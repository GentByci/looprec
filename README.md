# LoopRec

One button to record whatever Windows is playing. Saves a 24-bit WAV and a 320 kbps MP3, then opens
the folder with the new file selected so you can drag it straight into your DAW.

- Records the **system output** (WASAPI loopback) — YouTube, Spotify, a browser tab, a game, anything.
- No drivers, no virtual cables, no routing changes. You keep hearing audio normally.
- **Ctrl+Alt+R** starts and stops from anywhere while the window is open.
- ~400 KB. Two NAudio DLLs plus a few PowerShell scripts; nothing is installed system-wide.

## Install

Windows 10/11. Nothing else needed — it runs on the PowerShell and .NET that ship with Windows.

1. Download this repo (Code → Download ZIP, or `git clone`) and unzip it somewhere permanent.
2. Open a terminal in that folder and run:

   ```
   powershell -ExecutionPolicy Bypass -File setup.ps1
   ```

   This downloads NAudio (two files from NuGet), compiles the small capture core, and puts a
   **LoopRec** shortcut on your desktop.

If you downloaded a ZIP and Windows complains the scripts are blocked, run
`Unblock-File *.ps1` in the folder first.

## Use

Double-click **LoopRec** on the desktop.

| | |
|---|---|
| **Record / Stop** | the big button, or `Ctrl+Alt+R` from any app, or launch LoopRec again |
| **Source** | follows the Windows default output, or pick a specific device |
| **Save to** | type a path or Browse; remembered between runs |
| **WAV / MP3** | keep one or both |

Files are named by time: `2026-09-21 17-48-30.wav`.

There is also a no-window version, `looprec-cli.ps1`: launch it to start, launch it again (or press
a key in its console) to stop. It reads the same settings.

## Settings

Everything the window changes is stored in `config.json` next to the scripts. Two things are only
there:

| key | default | |
|---|---|---|
| `hotkey` | `"Ctrl+Alt+R"` | modifiers `Ctrl`, `Alt`, `Shift`, `Win` + a letter, digit or F-key; `""` disables |
| `mp3Bitrate` | `320000` | bits per second |

## How it works

`LoopRec.cs` (compiled once into `lib\LoopRec.Native.dll`) opens a WASAPI loopback capture on the
output device through [NAudio](https://github.com/naudio/NAudio). While recording it also plays
silence into that device: Windows delivers no loopback data at all while a device is idle, so without
this every pause in playback would simply be missing from the file. Capture is 32-bit float; on stop
it is written out as 24-bit WAV and, through the MP3 encoder built into Windows Media Foundation, as MP3.

The window is WPF rather than WinForms on purpose: the first `System.Drawing.Font` in a process makes
GDI+ enumerate every installed font, which takes many seconds on machines with large font libraries.

## Troubleshooting

- **"Could not start capturing: Not implemented"** — that output device's driver refuses loopback
  (seen with some USB DACs). Pick another Source, or route the app you're capturing to your speakers.
- **MP3 missing, WAV fine** — Windows N editions lack Media Foundation; install the Media Feature Pack
  or just use WAV.
- **Hotkey message in the window** — another app owns that key combination; change `hotkey` in
  `config.json`.
- A log of each session is written to `%TEMP%\LoopRec.log`.

## License

MIT. NAudio is MIT-licensed by Mark Heath and contributors.
