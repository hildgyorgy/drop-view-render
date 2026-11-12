using System.Diagnostics;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;
using System.Threading.Channels;

namespace DropViewRender;

public sealed class RenderJob(string origin, string input, Package package, string output)
{
    public string Id { get; } = Guid.NewGuid().ToString();
    public string Origin { get; } = origin;
    public string Input { get; } = input;
    public Package Package { get; } = package;
    public string Output { get; } = output;
    public string State { get; set; } = "queued";
    public string? Error { get; set; }
    public string? Device { get; set; }
    public double? Progress { get; set; }
    public Stopwatch Clock { get; } = new();
    public CancellationTokenSource Cancel { get; } = new();
}

public interface IRenderExecutor
{
    Task RunAsync(RenderJob job, string stagedOutput, Action<double> progress, CancellationToken cancellation);
}

public sealed class BlenderExecutor(Func<string?> blender, string adapter, string scratchRoot,
    Action<Process>? ownProcess = null, string? logRoot = null) : IRenderExecutor
{
    public async Task RunAsync(RenderJob job, string stagedOutput, Action<double> progress, CancellationToken cancellation)
    {
        string executable = blender() ?? throw new InvalidOperationException("Choose Blender 5.3.0 in the tray menu.");
        string scratch = Path.Combine(scratchRoot, job.Id);
        Directory.CreateDirectory(scratch);
        StreamWriter? log = null;
        int logCharacters = 0;
        var logSync = new object();
        if (logRoot != null)
        {
            try
            {
                Directory.CreateDirectory(logRoot);
                foreach (var old in new DirectoryInfo(logRoot).GetFiles("*.log").OrderByDescending(f => f.LastWriteTimeUtc).Skip(31)) old.Delete();
                log = new StreamWriter(new FileStream(Path.Combine(logRoot, job.Id + ".log"), FileMode.CreateNew, FileAccess.Write, FileShare.Read));
            }
            catch (Exception error) when (error is IOException or UnauthorizedAccessException) { /* Diagnostics must not prevent rendering. */ }
        }
        var info = new ProcessStartInfo(executable)
        { UseShellExecute = false, CreateNoWindow = true, RedirectStandardOutput = true, RedirectStandardError = true };
        foreach (string arg in new[] { "--background", "--factory-startup", "--python-exit-code", "1", "--python", adapter,
                     "--", job.Input, "--output", stagedOutput, "--width", job.Package.Width.ToString(), "--height", job.Package.Height.ToString(),
                     "--samples", job.Package.Samples.ToString(), "--bounces", job.Package.Bounces.ToString(), "--transmission-bounces", job.Package.TransmissionBounces.ToString(),
                     "--adaptive-sampling", "--noise-threshold", "0.03", "--denoise", "--device", "AUTO" }) info.ArgumentList.Add(arg);
        info.Environment["TMP"] = scratch; info.Environment["TEMP"] = scratch; info.Environment["TMPDIR"] = scratch;
        using var process = new Process { StartInfo = info };
        try
        {
            cancellation.ThrowIfCancellationRequested();
            if (!process.Start()) throw new IOException("Could not start Blender.");
            try { ownProcess?.Invoke(process); }
            catch { if (!process.HasExited) process.Kill(true); throw; }
            using var cancel = cancellation.Register(() => { try { if (!process.HasExited) process.Kill(true); } catch (InvalidOperationException) { } });
            async Task Drain(StreamReader reader)
            {
                // ReadLine is bounded manually: Blender output cannot grow a huge UI/log buffer.
                var buffer = new char[2048]; string tail = "";
                while (true)
                {
                    int count = await reader.ReadAsync(buffer);
                    if (count == 0) break;
                    string text = new(buffer, 0, count);
                    lock (logSync)
                    {
                        if (log != null && logCharacters < 1_000_000)
                        {
                            try { log.Write(text[..Math.Min(text.Length, 1_000_000 - logCharacters)]); log.Flush(); logCharacters += text.Length; }
                            catch (IOException) { }
                        }
                    }
                    tail += text;
                    var device = Regex.Match(tail, @"\[Drop & View Cycles\] (.+? devices: [^\r\n]+|No compatible GPU found; using CPU\.|CPU rendering)");
                    if (device.Success) job.Device = device.Groups[1].Value;
                    foreach (Match match in Regex.Matches(tail, @"DVR_PROGRESS (\d+)/(\d+)", RegexOptions.CultureInvariant))
                        if (double.TryParse(match.Groups[1].Value, out double current) && double.TryParse(match.Groups[2].Value, out double total) && total > 0)
                            progress(Math.Clamp(current / total, 0, 1));
                    tail = tail[^Math.Min(tail.Length, 100)..];
                }
            }
            await Task.WhenAll(Drain(process.StandardOutput), Drain(process.StandardError), process.WaitForExitAsync());
            cancellation.ThrowIfCancellationRequested();
            if (process.ExitCode != 0) throw new IOException($"Blender exited with code {process.ExitCode}. Check Blender/GPU compatibility.");
        }
        finally
        {
            try { log?.Dispose(); } catch (IOException) { }
            try { Directory.Delete(scratch, true); } catch (Exception error) when (error is IOException or UnauthorizedAccessException) { }
        }
    }
}

public sealed class RenderQueue : IAsyncDisposable
{
    private readonly object sync = new();
    private readonly Channel<RenderJob> waiting = Channel.CreateUnbounded<RenderJob>(new UnboundedChannelOptions { SingleReader = true });
    private readonly List<RenderJob> jobs = [];
    private readonly IRenderExecutor executor;
    private readonly Task worker;
    private bool stopping;
    public event Action? Changed;
    public RenderQueue(IRenderExecutor executor) { this.executor = executor; worker = Task.Run(WorkAsync); }
    public IReadOnlyList<RenderJob> Jobs { get { lock (sync) return jobs.ToArray(); } }
    public bool Rendering { get { lock (sync) return jobs.Any(j => j.State == "rendering"); } }
    public RenderJob Add(string origin, string input, Package package, string directory)
    {
        lock (sync)
        {
            if (stopping) throw new BridgeException("renderer_stopping", 503);
            if (jobs.Count >= 128) throw new BridgeException("session_job_limit", 429);
            Directory.CreateDirectory(directory);
            string stem = Path.GetFileNameWithoutExtension(package.FileName) + "-cycles";
            string output; int index = 0;
            do { output = Path.Combine(directory, stem + (index == 0 ? "" : $"-{index:000}") + ".png"); index++; }
            while (File.Exists(output) || jobs.Any(j => j.Output == output));
            var job = new RenderJob(origin, input, package, output);
            jobs.Add(job); waiting.Writer.TryWrite(job); Changed?.Invoke(); return job;
        }
    }
    private RenderJob Find(string origin, string id) => jobs.FirstOrDefault(j => j.Id == id && j.Origin == origin)
        ?? throw new BridgeException("job_not_found", 404);
    public JsonObject Status(string origin, string id)
    {
        lock (sync)
        {
            var job = Find(origin, id);
            var result = Protocol.Object(("id", job.Id), ("state", job.State), ("elapsed", job.Clock.Elapsed.TotalSeconds),
                ("outputName", Path.GetFileName(job.Output)), ("device", job.Device), ("progress", job.Progress), ("error", job.Error),
                ("settings", new { profile = "recommended", width = job.Package.Width, height = job.Package.Height, samples = job.Package.Samples,
                    bounces = job.Package.Bounces, transmissionBounces = job.Package.TransmissionBounces, denoise = true, adaptiveSampling = true, noiseThreshold = 0.03 }));
            if (job.State == "queued") result["queuePosition"] = jobs.Where(j => j.State == "queued").TakeWhile(j => j != job).Count() + 1;
            return result;
        }
    }
    public void Cancel(string origin, string id) { lock (sync) CancelJob(Find(origin, id)); }
    public void CancelAll() { lock (sync) foreach (var job in jobs) CancelJob(job); }
    private void CancelJob(RenderJob job)
    {
        if (job.State is not ("queued" or "rendering")) return;
        job.Cancel.Cancel(); if (job.State == "queued") job.State = "cancelled"; Changed?.Invoke();
    }
    public string FinishedOutput(string origin, string id)
    {
        lock (sync)
        {
            var job = Find(origin, id);
            if (job.State != "finished" || !File.Exists(job.Output)) throw new BridgeException("output_unavailable", 409);
            return job.Output;
        }
    }
    private async Task WorkAsync()
    {
        await foreach (var job in waiting.Reader.ReadAllAsync())
        {
            lock (sync) { if (job.State == "cancelled") continue; job.State = "rendering"; job.Clock.Start(); }
            Changed?.Invoke();
            string staged = Path.Combine(Path.GetDirectoryName(job.Output)!, ".drop-view-render-" + job.Id + ".png");
            try
            {
                await executor.RunAsync(job, staged, value => { lock (sync) job.Progress = value; Changed?.Invoke(); }, job.Cancel.Token);
                lock (sync)
                {
                    job.Cancel.Token.ThrowIfCancellationRequested();
                    if (!File.Exists(staged) || new FileInfo(staged).Length == 0) throw new IOException("Blender did not create an image.");
                    File.Move(staged, job.Output, false); // Never overwrite an existing image, even after a race.
                    job.State = "finished";
                }
            }
            catch (OperationCanceledException) { lock (sync) job.State = "cancelled"; }
            catch (Exception error) { lock (sync) { job.State = job.Cancel.IsCancellationRequested ? "cancelled" : "failed"; job.Error = error.Message; } }
            finally { job.Clock.Stop(); try { File.Delete(staged); } catch (IOException) { } Changed?.Invoke(); }
        }
    }
    public async ValueTask DisposeAsync()
    {
        lock (sync) { stopping = true; CancelAll(); waiting.Writer.TryComplete(); }
        await worker;
        foreach (var job in Jobs) job.Cancel.Dispose();
    }
}
