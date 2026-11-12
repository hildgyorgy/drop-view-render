using DropViewRender;
using Microsoft.Win32;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Text.Json;
using Microsoft.Win32.SafeHandles;

namespace DropViewRenderTray;

internal static class Program
{
    [STAThread]
    public static void Main()
    {
        using var singleInstance = new Mutex(true, @"Local\DropViewRender.Tray", out bool created);
        if (!created) return;
        ApplicationConfiguration.Initialize();
        try { using var context = new TrayContext(); Application.Run(context); }
        catch (Exception error) { MessageBox.Show(error.Message, "Drop & View Render could not start"); }
    }
}

internal sealed record Settings(string? Blender = null, string? Output = null);

internal sealed class TrayContext : ApplicationContext
{
    private readonly Control dispatcher = new();
    private readonly NotifyIcon icon;
    private readonly ToolStripMenuItem status = new("Starting…") { Enabled = false };
    private readonly ToolStripMenuItem login = new("Start when I sign in") { CheckOnClick = true };
    private readonly ToolStripMenuItem blenderItem = new("Choose Blender 5.3.0…");
    private readonly string support = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "DropViewRender");
    private readonly string session;
    private readonly RenderQueue queue;
    private readonly Bridge bridge;
    private readonly PipeServer server;
    private readonly ProcessOwnership ownership = new();
    private readonly Dictionary<string, string> seen = [];
    private Settings settings;
    private volatile string? verifiedBlender;
    private bool stopping;
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";

    public TrayContext()
    {
        _ = dispatcher.Handle;
        Directory.CreateDirectory(support);
        try { settings = JsonSerializer.Deserialize<Settings>(File.ReadAllText(Path.Combine(support, "settings.json"))) ?? new(); }
        catch (Exception error) when (error is IOException or JsonException or UnauthorizedAccessException) { settings = new(); }
        string sessions = Path.Combine(support, "Sessions", Process.GetCurrentProcess().SessionId.ToString());
        Directory.CreateDirectory(sessions);
        foreach (string old in Directory.GetDirectories(sessions).Where(p => Guid.TryParse(Path.GetFileName(p), out _)))
            try { Directory.Delete(old, true); } catch (IOException) { }
        session = Path.Combine(sessions, Guid.NewGuid().ToString());
        Directory.CreateDirectory(session);
        queue = new RenderQueue(new BlenderExecutor(() => verifiedBlender,
            Path.Combine(AppContext.BaseDirectory, "Resources", "render_glb.py"), Path.Combine(session, "scratch"), ownership.Assign, Path.Combine(support, "Logs")));
        bridge = new Bridge(Path.Combine(session, "inputs"), queue, ApproveAsync, () => verifiedBlender != null, OutputDirectory, Reveal);
        server = new PipeServer(bridge, PipeAddress.Current);
        var menu = new ContextMenuStrip();
        menu.Items.Add(status);
        menu.Items.Add("Open Drop & View", null, (_, _) => Open("https://hildgyorgy.github.io/drop-3d-view/"));
        menu.Items.Add("Open output folder", null, (_, _) => { Directory.CreateDirectory(OutputDirectory()); Open(OutputDirectory()); });
        menu.Items.Add("Open diagnostics", null, (_, _) => { string logs = Path.Combine(support, "Logs"); Directory.CreateDirectory(logs); Open(logs); });
        menu.Items.Add("Choose output folder…", null, (_, _) =>
        {
            using var dialog = new FolderBrowserDialog { Description = "Choose the render output folder", InitialDirectory = OutputDirectory() };
            if (dialog.ShowDialog() == DialogResult.OK) { settings = settings with { Output = dialog.SelectedPath }; Save(); }
        });
        menu.Items.Add("Browser extension folder", null, (_, _) => Open(Path.Combine(AppContext.BaseDirectory, "ChromiumExtension")));
        menu.Items.Add(blenderItem);
        blenderItem.Click += async (_, _) =>
        {
            using var dialog = new OpenFileDialog { Filter = "Blender executable (blender.exe)|blender.exe", Title = "Choose Blender 5.3.0" };
            if (dialog.ShowDialog() != DialogResult.OK) return;
            if (await VerifyBlenderAsync(dialog.FileName)) { settings = settings with { Blender = dialog.FileName }; Save(); Update(); }
            else MessageBox.Show("Choose stable Blender 5.3.0 (or a newer 5.3 maintenance release). Blender 5.2.3 LTS remains supported.", "Drop & View Render");
        };
        menu.Items.Add(new ToolStripSeparator());
        menu.Items.Add("Cancel renders", null, (_, _) => queue.CancelAll());
        menu.Items.Add("Disconnect browsers", null, (_, _) => bridge.Revoke());
        using (var key = Registry.CurrentUser.OpenSubKey(RunKey)) login.Checked = key?.GetValue("DropViewRender") != null;
        login.CheckedChanged += (_, _) =>
        {
            try
            {
                using var key = Registry.CurrentUser.CreateSubKey(RunKey);
                if (login.Checked) key.SetValue("DropViewRender", '"' + Application.ExecutablePath + '"');
                else key.DeleteValue("DropViewRender", false);
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException)
            { MessageBox.Show(error.Message, "Could not update startup preference"); }
        };
        menu.Items.Add(login);
        menu.Items.Add("Quit", null, async (_, _) => await StopAsync());
        icon = new NotifyIcon { Icon = SystemIcons.Application, Text = "Drop & View Render", ContextMenuStrip = menu, Visible = true };
        icon.DoubleClick += (_, _) => { Directory.CreateDirectory(OutputDirectory()); Open(OutputDirectory()); };
        queue.Changed += () => { if (!dispatcher.IsDisposed) dispatcher.BeginInvoke(Update); };
        server.Start();
        _ = DiscoverBlenderAsync();
    }
    private string OutputDirectory() => settings.Output ?? Path.Combine(Downloads(), "Drop & View Render");
    private static string Downloads()
    {
        var id = new Guid("374DE290-123F-4565-9164-39C4925E467B");
        if (SHGetKnownFolderPath(ref id, 0, IntPtr.Zero, out var pointer) != 0)
            return Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads");
        try { return Marshal.PtrToStringUni(pointer)!; } finally { Marshal.FreeCoTaskMem(pointer); }
    }
    private void Save()
    {
        string path = Path.Combine(support, "settings.json"), staged = path + ".tmp";
        try { File.WriteAllText(staged, JsonSerializer.Serialize(settings)); File.Move(staged, path, true); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { MessageBox.Show(error.Message, "Could not save settings"); }
    }
    private Task<bool> ApproveAsync(string origin)
    {
        var completion = new TaskCompletionSource<bool>(TaskCreationOptions.RunContinuationsAsynchronously);
        dispatcher.BeginInvoke(() =>
        {
            if (stopping) { completion.TrySetResult(false); return; }
            using var dialog = new Form
            {
                Text = "Connect to Drop & View?",
                ClientSize = new Size(480, 180),
                FormBorderStyle = FormBorderStyle.FixedDialog,
                MaximizeBox = false,
                MinimizeBox = false,
                StartPosition = FormStartPosition.CenterScreen,
                TopMost = true
            };
            dialog.Controls.Add(new Label
            {
                Text = $"Allow {origin} until this app quits?\n\nThis permits scene uploads, rendering, cancellation and showing completed images.",
                Location = new Point(20, 15),
                Size = new Size(440, 100)
            });
            var allow = new Button { Text = "Allow", DialogResult = DialogResult.Yes, Location = new Point(370, 135) };
            var deny = new Button { Text = "Deny", DialogResult = DialogResult.No, Location = new Point(280, 135) };
            dialog.Controls.Add(allow); dialog.Controls.Add(deny); dialog.AcceptButton = allow; dialog.CancelButton = deny;
            using var timeout = new System.Windows.Forms.Timer { Interval = 105000, Enabled = true };
            timeout.Tick += (_, _) => dialog.Close();
            completion.TrySetResult(dialog.ShowDialog() == DialogResult.Yes && !stopping);
        });
        return completion.Task;
    }
    private async Task DiscoverBlenderAsync()
    {
        var candidates = new List<string>();
        if (settings.Blender != null) candidates.Add(settings.Blender);
        string foundation = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.ProgramFiles), "Blender Foundation");
        if (Directory.Exists(foundation)) candidates.AddRange(Directory.GetDirectories(foundation, "Blender 5.*")
            .Where(folder => Path.GetFileName(folder).StartsWith("Blender 5.3", StringComparison.Ordinal) ||
                             Path.GetFileName(folder).StartsWith("Blender 5.2", StringComparison.Ordinal))
            .OrderByDescending(folder => Version.TryParse(Path.GetFileName(folder)[8..], out var version) ? version : new Version(0, 0))
            .Select(folder => Path.Combine(folder, "blender.exe")));
        foreach (string candidate in candidates) if (await VerifyBlenderAsync(candidate)) break;
        Update();
        if (verifiedBlender == null) icon.ShowBalloonTip(5000, "Choose Blender", "Install Blender 5.3.0, then choose it from this tray menu.", ToolTipIcon.Info);
    }
    private async Task<bool> VerifyBlenderAsync(string path)
    {
        if (!File.Exists(path)) return false;
        using var process = new Process
        {
            StartInfo = new ProcessStartInfo(path, "--version")
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true }
        };
        try
        {
            process.Start();
            Task<string> output = process.StandardOutput.ReadToEndAsync();
            Task<string> errors = process.StandardError.ReadToEndAsync();
            try { await process.WaitForExitAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token); }
            catch (OperationCanceledException) { process.Kill(true); return false; }
            string version = await output; await errors;
            if (process.ExitCode != 0 || !BlenderVersion.IsSupported(version)) return false;
            verifiedBlender = path; return true;
        }
        catch (Exception error) when (error is IOException or System.ComponentModel.Win32Exception or InvalidOperationException) { return false; }
    }
    private void Update()
    {
        if (stopping) return;
        var jobs = queue.Jobs;
        var active = jobs.FirstOrDefault(job => job.State == "rendering");
        status.Text = active != null ? $"Rendering · {active.Progress.GetValueOrDefault():P0} · {Path.GetFileName(active.Output)}"
            : verifiedBlender != null ? "Ready" : "Choose Blender 5.3.0…";
        icon.Text = active != null ? "Drop & View Render · Rendering" : "Drop & View Render · " + (verifiedBlender != null ? "Ready" : "Choose Blender");
        foreach (var job in jobs)
        {
            if (seen.GetValueOrDefault(job.Id) == job.State) continue;
            seen[job.Id] = job.State;
            if (job.State is "finished" or "failed") icon.ShowBalloonTip(4000, "Drop & View Render",
                job.State == "finished" ? "Finished: " + Path.GetFileName(job.Output) : job.Error ?? "Render failed.",
                job.State == "finished" ? ToolTipIcon.Info : ToolTipIcon.Error);
        }
    }
    private static void Open(string path) => Process.Start(new ProcessStartInfo(path) { UseShellExecute = true });
    private static void Reveal(string path)
    {
        var info = new ProcessStartInfo("explorer.exe") { UseShellExecute = false };
        info.ArgumentList.Add("/select," + path); Process.Start(info);
    }
    private async Task StopAsync()
    {
        if (stopping) return;
        if (queue.Jobs.Any(job => job.State is "queued" or "rendering") && MessageBox.Show("Stop pending/running renders and quit?",
            "Drop & View Render", MessageBoxButtons.YesNo) != DialogResult.Yes) return;
        stopping = true; queue.CancelAll();
        await server.DisposeAsync(); await queue.DisposeAsync(); await bridge.DisposeAsync(); ownership.Dispose();
        icon.Visible = false;
        try { Directory.Delete(session, true); } catch (IOException) { }
        ExitThread();
    }
    protected override void Dispose(bool disposing)
    {
        if (disposing) { ownership.Dispose(); icon.Dispose(); dispatcher.Dispose(); }
        base.Dispose(disposing);
    }
    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    private static extern int SHGetKnownFolderPath(ref Guid id, uint flags, IntPtr token, out IntPtr path);
}

internal sealed class ProcessOwnership : IDisposable
{
    private readonly SafeFileHandle job;
    public ProcessOwnership()
    {
        job = CreateJobObject(IntPtr.Zero, null);
        var limits = new ExtendedLimits { Basic = new BasicLimits { Flags = 0x2000 } }; // KILL_ON_JOB_CLOSE
        int size = Marshal.SizeOf<ExtendedLimits>(); var memory = Marshal.AllocHGlobal(size);
        try
        {
            Marshal.StructureToPtr(limits, memory, false);
            if (job.IsInvalid || !SetInformationJobObject(job, 9, memory, (uint)size)) throw new System.ComponentModel.Win32Exception();
        }
        finally { Marshal.FreeHGlobal(memory); }
    }
    public void Assign(Process process) { if (!AssignProcessToJobObject(job, process.Handle)) throw new System.ComponentModel.Win32Exception(); }
    public void Dispose() => job.Dispose();
    [StructLayout(LayoutKind.Sequential)]
    private struct BasicLimits
    { public long ProcessTime, JobTime; public uint Flags; public UIntPtr MinWorking, MaxWorking; public uint Active; public UIntPtr Affinity; public uint Priority, Scheduling; }
    [StructLayout(LayoutKind.Sequential)] private struct IoCounters { public ulong ReadOps, WriteOps, OtherOps, ReadBytes, WriteBytes, OtherBytes; }
    [StructLayout(LayoutKind.Sequential)]
    private struct ExtendedLimits
    { public BasicLimits Basic; public IoCounters Io; public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)] private static extern SafeFileHandle CreateJobObject(IntPtr security, string? name);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool SetInformationJobObject(SafeFileHandle job, int type, IntPtr limits, uint length);
    [DllImport("kernel32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool AssignProcessToJobObject(SafeFileHandle job, IntPtr process);
}
