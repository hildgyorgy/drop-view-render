using DropViewRender;
using System.Buffers.Binary;
using System.IO.Pipes;
using System.Text;
using System.Text.Json.Nodes;

internal static class Program
{
    private static int checks;
    private static void Check(bool condition, string message)
    { checks++; if (!condition) throw new InvalidOperationException("FAIL: " + message); }
    private static async Task Wait(Func<bool> condition)
    {
        for (int i = 0; i < 1000; i++) { if (condition()) return; await Task.Delay(10); }
        throw new TimeoutException("Test condition not reached");
    }
    private static byte[] EncodePackage(int samples = 37)
    {
        var manifest = Protocol.Object(("version", 1), ("fileName", "house.glb"), ("viewSession", new { }), ("producer", new { }),
            ("renderSize", new { width = 64, height = 48 }), ("renderJob", new { samples, bounces = 8, transmissiveBounces = 12 }), ("lengths", new[] { 12 }));
        byte[] json = Encoding.UTF8.GetBytes(manifest.ToJsonString());
        byte[] data = new byte[12 + json.Length + 12];
        "DVRENDER"u8.CopyTo(data); BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(8), (uint)json.Length); json.CopyTo(data, 12);
        "glTF"u8.CopyTo(data.AsSpan(12 + json.Length)); BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(16 + json.Length), 2);
        BinaryPrimitives.WriteUInt32LittleEndian(data.AsSpan(20 + json.Length), 12); return data;
    }
    private sealed class FakeExecutor : IRenderExecutor
    {
        public int Active, Maximum;
        public bool Fail;
        public async Task RunAsync(RenderJob job, string output, Action<double> progress, CancellationToken cancellation)
        {
            int active = Interlocked.Increment(ref Active); Maximum = Math.Max(Maximum, active);
            try
            {
                await Task.Delay(80, cancellation); progress(0.5);
                if (Fail) throw new IOException("Test failure");
                await File.WriteAllBytesAsync(output, [137, 80, 78, 71, 13, 10, 26, 10], cancellation);
            }
            finally { Interlocked.Decrement(ref Active); }
        }
    }
    public static async Task<int> Main(string[] args)
    {
        string root = Path.Combine(Path.GetTempPath(), "dvr-windows-tests-" + Guid.NewGuid()); Directory.CreateDirectory(root);
        try
        {
            var bytes = EncodePackage(); string source = Path.Combine(root, "scene.dvrender"); await File.WriteAllBytesAsync(source, bytes);
            var package = await Package.ReadAsync(source);
            Check(package.Samples == 37 && package.Bounces == 8 && package.TransmissionBounces == 12, "source targets are preserved");
            foreach (string name in new[] { "../escape.glb", "C:\\escape.glb", "a/b.glb", ".", "bad\n.glb", "trailing. " })
                Check(!Package.SafeName(name), "unsafe filename rejected");
            await File.WriteAllBytesAsync(source, [.. bytes, 0]);
            try { await Package.ReadAsync(source); Check(false, "trailing package accepted"); } catch (BridgeException) { checks++; }
            await File.WriteAllBytesAsync(source, bytes);
            foreach (var malformed in new[] { new byte[4], new byte[] { 161, 134, 1, 0 }, new byte[] { 4, 0, 0, 0, 123 } })
                try { await Protocol.ReadAsync(new MemoryStream(malformed)); Check(false, "bad frame accepted"); }
                catch (Exception error) when (error is BridgeException or EndOfStreamException) { checks++; }
            using (var frame = new MemoryStream())
            {
                await Protocol.WriteAsync(frame, Protocol.Object(("text", "Üveg 🪟"))); frame.Position = 0;
                Check((await Protocol.ReadAsync(frame))!["text"]!.GetValue<string>() == "Üveg 🪟", "framed Unicode roundtrip");
            }
            var executor = new FakeExecutor();
            await using var queue = new RenderQueue(executor);
            int approvals = 0; string? revealed = null;
            await using var bridge = new Bridge(Path.Combine(root, "uploads"), queue, _ => { approvals++; return Task.FromResult(true); },
                () => true, () => Path.Combine(root, "output"), path => revealed = path);
            string? token = null;
            async Task<JsonObject> Request(string op, JsonObject? fields = null, string? credential = null, string? page = null)
            {
                var request = fields ?? new JsonObject(); request["protocolVersion"] = 1; request["id"] = Guid.NewGuid().ToString();
                request["operation"] = op; request["pageURL"] = page ?? "https://hildgyorgy.github.io/drop-3d-view/";
                if ((credential ?? token) is { } t) request["token"] = t;
                return await bridge.HandleAsync(request);
            }
            static JsonObject Data(JsonObject response) => response["data"]?.AsObject() ?? throw new Exception(response.ToJsonString());
            Check((await Request("pair", page: "https://hildgyorgy.github.io/other/"))["error"]!.GetValue<string>() == "origin_not_allowed" && approvals == 0, "origin checked before approval");
            token = Data(await Request("pair"))["token"]!.GetValue<string>();
            Check(token.Length == 72 && approvals == 1, "memory-only pairing");
            Check((await Request("status", credential: new string('a', 72)))["status"]!.GetValue<int>() == 401, "unknown credential denied");
            Check((await Request("status", page: "http://localhost:9999/"))["status"]!.GetValue<int>() == 401, "credentials bind to origin");
            string key = Guid.NewGuid().ToString();
            string upload = Data(await Request("uploadBegin", Protocol.Object(("key", key), ("totalBytes", bytes.Length))))["uploadID"]!.GetValue<string>();
            JsonObject Chunk(byte[] payload, int offset = 0) => Protocol.Object(("uploadID", upload), ("offset", offset), ("base64", Convert.ToBase64String(payload)), ("digest", Protocol.Digest(payload)));
            Check((await Request("uploadFinish", Protocol.Object(("uploadID", upload))))["error"]!.GetValue<string>() == "incomplete_upload", "cannot commit incomplete upload");
            var bad = Chunk(bytes); bad["digest"] = new string('0', 64);
            Check((await Request("uploadChunk", bad))["error"]!.GetValue<string>() == "invalid_chunk", "checksum verified");
            Check((await Request("uploadChunk", Chunk(bytes[1..], 1)))["error"]!.GetValue<string>() == "invalid_offset", "ordered offsets required");
            Check(Data(await Request("uploadChunk", Chunk(bytes)))["offset"]!.GetValue<long>() == bytes.Length, "chunk acknowledged");
            Check(Data(await Request("uploadChunk", Chunk(bytes)))["offset"]!.GetValue<long>() == bytes.Length, "identical prefix replay acknowledged");
            var changed = (byte[])bytes.Clone(); changed[^1] ^= 1;
            Check((await Request("uploadChunk", Chunk(changed)))["error"]!.GetValue<string>() == "chunk_conflict", "changed prefix rejected");
            string secondToken = Data(await Request("pair"))["token"]!.GetValue<string>();
            Check((await Request("uploadChunk", Chunk(bytes), secondToken))["error"]!.GetValue<string>() == "upload_not_found", "upload owner isolation");
            var finish = Protocol.Object(("uploadID", upload));
            string job = Data(await Request("uploadFinish", finish))["id"]!.GetValue<string>();
            Check(Data(await Request("uploadFinish", finish))["id"]!.GetValue<string>() == job, "finish replay returns same job");
            async Task<string> Upload(string submissionKey, byte[] contents)
            {
                string id = Data(await Request("uploadBegin", Protocol.Object(("key", submissionKey), ("totalBytes", contents.Length))))["uploadID"]!.GetValue<string>();
                await Request("uploadChunk", Protocol.Object(("uploadID", id), ("offset", 0), ("base64", Convert.ToBase64String(contents)), ("digest", Protocol.Digest(contents))));
                return Data(await Request("uploadFinish", Protocol.Object(("uploadID", id))))["id"]!.GetValue<string>();
            }
            Check(await Upload(key, bytes) == job && queue.Jobs.Count == 1, "whole-submission dedup");
            string next = await Upload(Guid.NewGuid().ToString(), bytes);
            await Wait(() => queue.Jobs.All(j => j.State == "finished"));
            Check(executor.Maximum == 1, "queue is serial");
            Check(queue.Jobs[0].Output != queue.Jobs[1].Output && queue.Jobs[1].Output.EndsWith("-001.png", StringComparison.Ordinal), "indexed rerender preserves image");
            await Request("reveal", Protocol.Object(("jobID", job)));
            Check(revealed == queue.Jobs[0].Output, "owned finished output reveal");
            Check((await Request("job", Protocol.Object(("jobID", next)), secondToken, "http://localhost/"))["status"]!.GetValue<int>() == 401, "job origin isolation");
            string aborted = Data(await Request("uploadBegin", Protocol.Object(("key", Guid.NewGuid().ToString()), ("totalBytes", bytes.Length))))["uploadID"]!.GetValue<string>();
            await Request("uploadAbort", Protocol.Object(("uploadID", aborted)));
            Check((await Request("uploadFinish", Protocol.Object(("uploadID", aborted))))["error"]!.GetValue<string>() == "upload_not_found", "abort never queues");
            var active = queue.Add("test", source, package, Path.Combine(root, "cancel"));
            var queued = queue.Add("test", source, package, Path.Combine(root, "cancel"));
            queue.Cancel("test", queued.Id); await Wait(() => active.State == "rendering"); queue.Cancel("test", active.Id);
            await Wait(() => active.State == "cancelled");
            Check(queued.State == "cancelled" && !File.Exists(active.Output) && !File.Exists(queued.Output), "active/queued cancel removes partial outputs");
            executor.Fail = true; var failed = queue.Add("test", source, package, Path.Combine(root, "failure"));
            await Wait(() => failed.State == "failed"); Check(!File.Exists(failed.Output), "failed renders do not publish output");
            string pipeName = "dvr-" + Guid.NewGuid().ToString("N")[..12];
            await using (var server = new PipeServer(bridge, pipeName))
            {
                server.Start();
                await using var client = new NamedPipeClientStream(".", pipeName, PipeDirection.InOut, PipeOptions.Asynchronous);
                await client.ConnectAsync(5000);
                await Protocol.WriteAsync(client, Protocol.Object(("id", Guid.NewGuid().ToString()), ("protocolVersion", 1),
                    ("pageURL", "http://127.0.0.1/"), ("operation", "ping"), ("text", "named pipe")));
                Check((await Protocol.ReadAsync(client))!["operation"]!.GetValue<string>() == "pong", "real named-pipe framed roundtrip");
            }
            bridge.Revoke();
            Check((await Request("status"))["status"]!.GetValue<int>() == 401, "revoke expires tokens");
            if (args.Length == 3) await RealRender(args[0], args[1], args[2], root);
            Console.WriteLine($"PASS: {checks} Windows core checks (package, auth, chunks, retries, queue, cancel, pipes)");
            return 0;
        }
        finally { Directory.Delete(root, true); }
    }
    private static async Task RealRender(string fixture, string blender, string adapter, string root)
    {
        var original = await File.ReadAllBytesAsync(fixture);
        int size = (int)BinaryPrimitives.ReadUInt32LittleEndian(original.AsSpan(8));
        var manifest = JsonNode.Parse(original.AsSpan(12, size))!.AsObject();
        manifest["renderSize"] = Protocol.Object(("width", 64), ("height", 48));
        manifest["renderJob"] = Protocol.Object(("samples", 1), ("bounces", 6), ("transmissiveBounces", 10));
        byte[] json = Encoding.UTF8.GetBytes(manifest.ToJsonString());
        string input = Path.Combine(root, "real.dvrender");
        await using (var file = File.Create(input))
        {
            file.Write("DVRENDER"u8); var length = new byte[4]; BinaryPrimitives.WriteUInt32LittleEndian(length, (uint)json.Length);
            file.Write(length); file.Write(json); file.Write(original.AsSpan(12 + size));
        }
        await using var queue = new RenderQueue(new BlenderExecutor(() => blender, adapter, Path.Combine(root, "real-scratch")));
        var job = queue.Add("test", input, await Package.ReadAsync(input), Path.Combine(root, "real-output"));
        using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(2));
        while (job.State is "queued" or "rendering") await Task.Delay(100, deadline.Token);
        Check(job.State == "finished" && new FileInfo(job.Output).Length > 8, "real Cycles process and final PNG");
        Check(job.Package.Width == 64 && job.Package.Samples == 1, "only test fixture quality reduced explicitly");
        Console.WriteLine("PASS: real .NET queue -> shared Blender adapter -> Cycles PNG");
    }
}
