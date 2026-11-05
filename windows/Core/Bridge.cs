using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;

namespace DropViewRender;

public sealed class Bridge : IAsyncDisposable
{
    private sealed class Upload(string owner, string key, long total, string path)
    {
        public string Owner = owner, Key = key, Path = path;
        public long Total = total, Received;
        public DateTime Touched = DateTime.UtcNow;
        public bool Committing;
        public string? Job;
    }
    private readonly object sync = new();
    private readonly Dictionary<string, string> sessions = [];
    private readonly Dictionary<string, Upload> uploads = [];
    private readonly Dictionary<string, (string Digest, string Job)> accepted = [];
    private readonly string root;
    private readonly RenderQueue queue;
    private readonly Func<string, Task<bool>> approve;
    private readonly Func<bool> blenderAvailable;
    private readonly Func<string> outputDirectory;
    private readonly Action<string> reveal;
    private long storedBytes;
    private int pairing;
    public Bridge(string root, RenderQueue queue, Func<string, Task<bool>> approve, Func<bool> blenderAvailable,
        Func<string> outputDirectory, Action<string> reveal)
    {
        this.root = root; this.queue = queue; this.approve = approve; this.blenderAvailable = blenderAvailable;
        this.outputDirectory = outputDirectory; this.reveal = reveal;
        Directory.CreateDirectory(root);
    }
    public void Revoke() { lock (sync) sessions.Clear(); }
    public async Task<JsonObject> HandleAsync(JsonObject request, CancellationToken cancellation = default)
    {
        string id = "";
        try
        {
            id = Protocol.Uuid(request, "id");
            if (Protocol.Integer(request, "protocolVersion") != 1) throw new BridgeException("unsupported_protocol");
            string origin = Protocol.Origin(Protocol.Text(request, "pageURL"));
            string operation = Protocol.Text(request, "operation", 32);
            if (operation == "ping")
            {
                var text = Protocol.Text(request, "text", 1024);
                if (Encoding.UTF8.GetByteCount(text) > 1024) throw new BridgeException("invalid_message");
                return Protocol.Object(("protocolVersion", 1), ("id", id), ("ok", true), ("transport", Protocol.Transport),
                    ("operation", "pong"), ("text", text), ("app", "Drop & View Render"), ("responder", "ChromiumNativeHost"),
                    ("nativeProcessID", Environment.ProcessId), ("capabilities", new[] { "ping" }));
            }
            if (operation == "pair")
            {
                lock (sync) if (sessions.Count >= 16) throw new BridgeException("session_limit", 429);
                if (Interlocked.CompareExchange(ref pairing, 1, 0) != 0) throw new BridgeException("pairing_busy", 429);
                try
                {
                    if (!await approve(origin).WaitAsync(TimeSpan.FromSeconds(110), cancellation)) throw new BridgeException("pairing_denied", 403);
                    var token = Guid.NewGuid().ToString() + Guid.NewGuid().ToString();
                    lock (sync) sessions[token] = origin;
                    return Protocol.Reply(id, Protocol.Object(("protocolVersion", 1), ("token", token)));
                }
                finally { Interlocked.Exchange(ref pairing, 0); }
            }
            string credential = Protocol.Text(request, "token", 72);
            lock (sync)
                if (!Protocol.TokenPattern().IsMatch(credential) || !sessions.TryGetValue(credential, out var owner) || owner != origin)
                    throw new BridgeException("pairing_required", 401);
            JsonObject data;
            switch (operation)
            {
                case "status": data = Protocol.Object(("app", "Drop & View Render"), ("appVersion", "0.3.0"), ("protocolVersion", 1),
                    ("capabilities", new[] { "status", "jobs", "cancel", "reveal" }), ("blenderAvailable", blenderAvailable()), ("rendering", queue.Rendering)); break;
                case "disconnect": lock (sync) sessions.Remove(credential); data = Protocol.Object(("disconnected", true)); break;
                case "job": data = queue.Status(origin, Protocol.Uuid(request, "jobID")); break;
                case "cancel": queue.Cancel(origin, Protocol.Uuid(request, "jobID")); data = Protocol.Object(("cancelled", true)); break;
                case "reveal": reveal(queue.FinishedOutput(origin, Protocol.Uuid(request, "jobID"))); data = Protocol.Object(("revealed", true)); break;
                case "uploadBegin": data = Begin(credential, request); break;
                case "uploadChunk": data = Append(credential, request); break;
                case "uploadAbort":
                    lock (sync)
                    {
                        string uploadId = Protocol.Uuid(request, "uploadID");
                        var upload = Get(credential, uploadId);
                        if (upload.Committing || upload.Job != null) throw new BridgeException("upload_committing", 409);
                        File.Delete(upload.Path); uploads.Remove(uploadId);
                    }
                    data = Protocol.Object(("aborted", true)); break;
                case "uploadFinish": data = await FinishAsync(origin, credential, Protocol.Uuid(request, "uploadID"), cancellation); break;
                default: throw new BridgeException("unsupported_operation");
            }
            return Protocol.Reply(id, data);
        }
        catch (BridgeException error) { return Protocol.Failure(id, error.Message, error.Status); }
        catch (TimeoutException) { return Protocol.Failure(id, "native_timeout", 504); }
        catch (OperationCanceledException) { return Protocol.Failure(id, "native_app_unavailable", 503); }
        catch (Exception error) when (error is IOException or UnauthorizedAccessException) { return Protocol.Failure(id, "native_storage_failed", 500); }
        catch (Exception error) when (error is FormatException or System.Text.Json.JsonException or InvalidOperationException or OverflowException)
        { return Protocol.Failure(id, "invalid_message"); }
    }
    private Upload Get(string owner, string id) => uploads.TryGetValue(id, out var upload) && upload.Owner == owner
        ? upload : throw new BridgeException("upload_not_found", 404);
    private JsonObject Begin(string owner, JsonObject request)
    {
        string key = Protocol.Uuid(request, "key"); long total = Protocol.Integer(request, "totalBytes");
        if (total < 24 || total > Package.MaximumBytes) throw new BridgeException("invalid_package_size");
        lock (sync)
        {
            foreach (var pair in uploads.Where(p => !p.Value.Committing && p.Value.Job == null && DateTime.UtcNow - p.Value.Touched > TimeSpan.FromMinutes(15)).ToArray())
            { File.Delete(pair.Value.Path); uploads.Remove(pair.Key); }
            var previous = uploads.FirstOrDefault(p => p.Value.Owner == owner && p.Value.Key == key && p.Value.Job == null);
            if (previous.Value != null)
            {
                if (previous.Value.Total != total) throw new BridgeException("idempotency_conflict", 409);
                previous.Value.Touched = DateTime.UtcNow;
                return Protocol.Object(("uploadID", previous.Key), ("offset", 0), ("chunkBytes", 65536));
            }
            var active = uploads.Values.Where(u => u.Job == null).ToArray();
            if (active.Length >= 4 || uploads.Count >= 128) throw new BridgeException("upload_busy", 429);
            if (active.Sum(u => u.Total) + total > 4L * 1024 * 1024 * 1024 || storedBytes + total > 8L * 1024 * 1024 * 1024)
                throw new BridgeException("upload_storage_full", 413);
            string id = Guid.NewGuid().ToString(), path = Path.Combine(root, id + ".dvrender");
            using (File.Create(path)) { }
            uploads[id] = new Upload(owner, key, total, path);
            return Protocol.Object(("uploadID", id), ("offset", 0), ("chunkBytes", 65536));
        }
    }
    private JsonObject Append(string owner, JsonObject request)
    {
        string id = Protocol.Uuid(request, "uploadID"), digest = Protocol.Text(request, "digest", 64);
        byte[] bytes = Convert.FromBase64String(Protocol.Text(request, "base64", 87384));
        if (bytes.Length is < 1 or > 65536 || Protocol.Digest(bytes) != digest) throw new BridgeException("invalid_chunk");
        long offset = Protocol.Integer(request, "offset");
        lock (sync)
        {
            var upload = Get(owner, id);
            if (upload.Committing || upload.Job != null) throw new BridgeException("upload_committing", 409);
            if (offset < 0 || offset > upload.Total - bytes.Length) throw new BridgeException("invalid_offset", 409);
            using var file = new FileStream(upload.Path, FileMode.Open, FileAccess.ReadWrite, FileShare.None);
            file.Position = offset;
            if (offset < upload.Received && offset + bytes.Length <= upload.Received)
            {
                var stored = new byte[bytes.Length]; file.ReadExactly(stored);
                if (!stored.AsSpan().SequenceEqual(bytes)) throw new BridgeException("chunk_conflict", 409);
            }
            else
            {
                if (offset != upload.Received) throw new BridgeException("invalid_offset", 409);
                file.Write(bytes); upload.Received += bytes.Length; file.SetLength(upload.Received);
            }
            upload.Touched = DateTime.UtcNow;
            return Protocol.Object(("uploadID", id), ("offset", offset + bytes.Length));
        }
    }
    private async Task<JsonObject> FinishAsync(string origin, string owner, string id, CancellationToken cancellation)
    {
        Upload upload;
        lock (sync)
        {
            upload = Get(owner, id);
            if (upload.Job != null) return Protocol.Object(("id", upload.Job));
            if (upload.Committing) throw new BridgeException("upload_committing", 409);
            if (upload.Received != upload.Total) throw new BridgeException("incomplete_upload", 409);
            upload.Committing = true;
        }
        try
        {
            var package = await Package.ReadAsync(upload.Path, cancellation);
            await using var file = new FileStream(upload.Path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
            string digest = Convert.ToHexStringLower(await SHA256.HashDataAsync(file, cancellation));
            await file.DisposeAsync();
            lock (sync)
            {
                // Approval may be revoked during a large validation/hash pass.
                if (!sessions.TryGetValue(owner, out string? activeOrigin) || activeOrigin != origin) throw new BridgeException("pairing_required", 401);
                string key = origin + "\n" + upload.Key;
                if (accepted.TryGetValue(key, out var prior))
                {
                    if (prior.Digest != digest) throw new BridgeException("idempotency_conflict", 409);
                    upload.Job = prior.Job; File.Delete(upload.Path);
                }
                else
                {
                    if (!blenderAvailable()) throw new BridgeException("blender_unavailable", 503);
                    var job = queue.Add(origin, upload.Path, package, outputDirectory());
                    upload.Job = job.Id; storedBytes += upload.Total; accepted[key] = (digest, job.Id);
                }
                return Protocol.Object(("id", upload.Job));
            }
        }
        finally { lock (sync) { upload.Committing = false; upload.Touched = DateTime.UtcNow; } }
    }
    public ValueTask DisposeAsync() { Revoke(); return ValueTask.CompletedTask; }
}
