// LoopRec capture core, compiled by core.ps1 into lib\LoopRec.Native.<edition>.dll. C# 5 only: Windows PowerShell's csc.
using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Threading;
using System.Threading.Tasks;
using NAudio.CoreAudioApi;
using NAudio.MediaFoundation;
using NAudio.Wave;
using NAudio.Wave.SampleProviders;

namespace LoopRec
{
    // WASAPI loopback of an output device to a float WAV. device: an endpoint ID, part of a device name, or empty for the Windows default.
    public class Recorder : IDisposable
    {
        private readonly WasapiLoopbackCapture capture;
        private readonly WaveFileWriter writer;
        private readonly WasapiOut keepAlive;
        private readonly object gate = new object();
        private float peak;
        private long flushedAt;
        private bool stopped;

        public string DeviceName { get; private set; }
        public Exception Error { get; private set; }
        public TimeSpan Elapsed { get { lock (gate) return writer.TotalTime; } }
        public long Bytes { get { lock (gate) return writer.Length; } }

        public Recorder(string tempPath, string device)
        {
            try
            {
                var endpoint = FindDevice(device);
                DeviceName = endpoint.FriendlyName;
                capture = new WasapiLoopbackCapture(endpoint);
                writer = new WaveFileWriter(tempPath, capture.WaveFormat);
                capture.DataAvailable += OnData;
                capture.RecordingStopped += (s, e) => Error = e.Exception;
                // Loopback delivers nothing while the endpoint is idle, so pauses in playback would vanish from
                // the file instead of being recorded as silence. A silent stream keeps the clock running.
                keepAlive = new WasapiOut(endpoint, AudioClientShareMode.Shared, false, 200);
                keepAlive.Init(new SilenceProvider(capture.WaveFormat));
                keepAlive.Play();
                capture.StartRecording();
            }
            catch
            {
                // e.g. a USB DAC that refuses loopback: stop the silence, close the file and remove it.
                Stop();
                if (writer != null) { try { File.Delete(tempPath); } catch { } }
                throw;
            }
        }

        private static MMDevice FindDevice(string device)
        {
            var all = new MMDeviceEnumerator();
            if (string.IsNullOrEmpty(device)) return all.GetDefaultAudioEndpoint(DataFlow.Render, Role.Multimedia);
            MMDevice byName = null;
            foreach (var d in all.EnumerateAudioEndPoints(DataFlow.Render, DeviceState.Active))
            {
                if (d.ID == device) return d;
                if (byName == null && d.FriendlyName.IndexOf(device, StringComparison.OrdinalIgnoreCase) >= 0) byName = d;
            }
            if (byName != null) return byName;
            throw new ArgumentException("The selected output device isn't connected (" + device + ").");
        }

        private void OnData(object sender, WaveInEventArgs e)
        {
            lock (gate)
            {
                writer.Write(e.Buffer, 0, e.BytesRecorded);
                // Rewrite the header every ~2 s so a crash or power cut still leaves a playable .recording.wav.
                if (writer.Length - flushedAt >= 2L * writer.WaveFormat.AverageBytesPerSecond) { writer.Flush(); flushedAt = writer.Length; }
                if (writer.WaveFormat.Encoding != WaveFormatEncoding.IeeeFloat) return;
                for (int i = 0; i + 3 < e.BytesRecorded; i += 4)
                {
                    float s = Math.Abs(BitConverter.ToSingle(e.Buffer, i));
                    if (s > peak) peak = s;
                }
            }
        }

        // Peak sample (0..1) since the last call; drives the level meter.
        public float TakePeak() { lock (gate) { float p = peak; peak = 0; return p; } }

        // Idempotent and safe on a half-built recorder. Elapsed and Bytes stay readable afterwards.
        public void Stop()
        {
            if (stopped) return;
            stopped = true;
            try { if (capture != null) capture.Dispose(); }   // stops and joins the capture thread
            finally
            {
                if (keepAlive != null) { try { keepAlive.Dispose(); } catch { } }
                if (writer != null) lock (gate) writer.Dispose();
            }
        }

        public void Dispose() { Stop(); }
    }

    public static class Native
    {
        [DllImport("user32.dll")] public static extern bool SetProcessDPIAware();
        [DllImport("shell32.dll", CharSet = CharSet.Unicode)] static extern uint ExtractIconEx(string file, int index, IntPtr[] large, IntPtr[] small, uint count);

        // HICON from an exe/dll, or IntPtr.Zero. System.Drawing could do it, but its first use enumerates every installed font.
        public static IntPtr ExtractIcon(string file, int index)
        {
            var icons = new IntPtr[1];
            ExtractIconEx(file, index, icons, null, 1);
            return icons[0];
        }
    }

    // The modern folder picker (IFileOpenDialog + FOS_PICKFOLDERS). Unused vtable slots are stubs: only their order matters.
    public static class FolderPicker
    {
        [ComImport, Guid("DC1C5A9C-E88A-4dde-A5A1-60F82A20AEF7")] class FileOpenDialog { }

        [ComImport, Guid("42f85136-db7e-439c-85f1-e4075d135fc8"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IFileDialog
        {
            [PreserveSig] int Show(IntPtr parent);
            void SetFileTypes(); void SetFileTypeIndex(); void GetFileTypeIndex(); void Advise(); void Unadvise();
            void SetOptions(uint fos);
            void GetOptions(); void SetDefaultFolder();
            void SetFolder(IShellItem item);
            void GetFolder(); void GetCurrentSelection(); void SetFileName(); void GetFileName();
            void SetTitle([MarshalAs(UnmanagedType.LPWStr)] string title);
            void SetOkButtonLabel(); void SetFileNameLabel();
            void GetResult(out IShellItem item);
        }

        [ComImport, Guid("43826d1e-e718-42ee-bc55-a1e261c37bfe"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
        interface IShellItem
        {
            void BindToHandler(); void GetParent();
            void GetDisplayName(uint sigdn, [MarshalAs(UnmanagedType.LPWStr)] out string name);
        }

        [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
        [return: MarshalAs(UnmanagedType.Interface)] static extern IShellItem SHCreateItemFromParsingName(string path, IntPtr bc, ref Guid iid);

        // Returns the chosen folder, or null if cancelled.
        public static string Show(IntPtr owner, string title, string initialPath)
        {
            var dialog = (IFileDialog)new FileOpenDialog();
            dialog.SetOptions(0x20 | 0x40 | 0x800);   // FOS_PICKFOLDERS | FOS_FORCEFILESYSTEM | FOS_PATHMUSTEXIST
            dialog.SetTitle(title);
            if (Directory.Exists(initialPath))
            {
                var iid = typeof(IShellItem).GUID;
                try { dialog.SetFolder(SHCreateItemFromParsingName(initialPath, IntPtr.Zero, ref iid)); } catch { }
            }
            if (dialog.Show(owner) != 0) return null;
            IShellItem item; dialog.GetResult(out item);
            string path; item.GetDisplayName(0x80058000, out path);   // SIGDN_FILESYSPATH
            return path;
        }
    }

    // System-wide hotkey on a message-only window. Create it on the UI thread and poll TakePress() from a timer.
    public class Hotkey : System.Windows.Forms.NativeWindow, IDisposable
    {
        [DllImport("user32.dll", SetLastError = true)] static extern bool RegisterHotKey(IntPtr hWnd, int id, uint mods, uint vk);
        [DllImport("user32.dll")] static extern bool UnregisterHotKey(IntPtr hWnd, int id);
        private int presses;
        public bool Registered { get; private set; }
        public string Error { get; private set; }

        // modifiers: 1 = Alt, 2 = Ctrl, 4 = Shift, 8 = Win. vk: virtual-key code ('R' = 0x52).
        public Hotkey(uint modifiers, uint vk)
        {
            CreateHandle(new System.Windows.Forms.CreateParams { Parent = new IntPtr(-3) });   // HWND_MESSAGE
            Registered = RegisterHotKey(Handle, 1, modifiers | 0x4000, vk);                    // MOD_NOREPEAT
            if (!Registered) Error = new System.ComponentModel.Win32Exception(Marshal.GetLastWin32Error()).Message;
        }

        protected override void WndProc(ref System.Windows.Forms.Message m)
        {
            if (m.Msg == 0x0312) Interlocked.Increment(ref presses);   // WM_HOTKEY
            base.WndProc(ref m);
        }

        public bool TakePress() { return Interlocked.Exchange(ref presses, 0) > 0; }
        public void Dispose() { if (Registered) UnregisterHotKey(Handle, 1); DestroyHandle(); }
    }

    public class ExportResult { public string[] Files; public string[] Warnings; }

    public static class Export
    {
        // Turns "<stem>.recording.wav" into <stem>.wav (24-bit) and/or <stem>.mp3, then deletes it. If neither could be
        // written, the temp file itself becomes <stem>.wav (32-bit float): a take is never thrown away.
        public static ExportResult Save(string tempPath, bool wav, bool mp3, int mp3Bitrate)
        {
            string stem = tempPath.EndsWith(".recording.wav") ? tempPath.Substring(0, tempPath.Length - 14) : Path.ChangeExtension(tempPath, null);
            var files = new List<string>(); var warnings = new List<string>();
            if (wav) { ToWav24(tempPath, stem + ".wav"); files.Add(stem + ".wav"); }
            if (mp3)
            {
                try { ToMp3(tempPath, stem + ".mp3", mp3Bitrate); files.Add(stem + ".mp3"); }
                catch (Exception e) { warnings.Add("MP3 failed: " + e.Message); try { File.Delete(stem + ".mp3"); } catch { } }
            }
            if (files.Count == 0) { File.Move(tempPath, stem + ".wav"); files.Add(stem + ".wav"); warnings.Add("kept as 32-bit float WAV"); }
            else File.Delete(tempPath);
            return new ExportResult { Files = files.ToArray(), Warnings = warnings.ToArray() };
        }

        // Same, off the UI thread: long takes take a while to read and encode.
        public static Task<ExportResult> SaveAsync(string tempPath, bool wav, bool mp3, int mp3Bitrate)
        {
            return Task.Run(() => Save(tempPath, wav, mp3, mp3Bitrate));
        }

        public static void ToWav24(string tempPath, string outPath)
        {
            using (var reader = new WaveFileReader(tempPath))
                WaveFileWriter.CreateWaveFile(outPath, new SampleToWaveProvider24(reader.ToSampleProvider()));
        }

        // Windows' own MP3 encoder (Media Foundation) wants 16-bit PCM at 44.1/48 kHz, mono or stereo.
        public static void ToMp3(string tempPath, string outPath, int bitrate)
        {
            MediaFoundationApi.Startup();
            using (var reader = new WaveFileReader(tempPath))
            {
                IWaveProvider pcm = new SampleToWaveProvider16(reader.ToSampleProvider());
                int rate = pcm.WaveFormat.SampleRate, channels = pcm.WaveFormat.Channels;
                if (channels > 2) throw new NotSupportedException("MP3 needs mono or stereo; the device is " + channels + "-channel.");
                var resampler = rate == 44100 || rate == 48000 ? null : new MediaFoundationResampler(pcm, new WaveFormat(48000, 16, channels));
                using (resampler) MediaFoundationEncoder.EncodeToMp3((IWaveProvider)resampler ?? pcm, outPath, bitrate);
            }
        }
    }
}
