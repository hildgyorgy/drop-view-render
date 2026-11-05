using DropViewRender;
using DropViewRenderTray;
using System.Diagnostics;

internal static class Program
{
    private sealed class NeverRender : IRenderExecutor
    {
        public Task RunAsync(RenderJob job, string output, Action<double> progress, CancellationToken cancellation) =>
            throw new InvalidOperationException("This IPC test must not render");
    }
    public static async Task Main(string[] args)
    {
        string bundle = Path.GetFullPath(args[0]);
        // Exercise actual Win32 ownership: closing the app's handle kills its child.
        using (var child = Process.Start(new ProcessStartInfo("cmd.exe", "/c ping -n 60 127.0.0.1 >NUL")
        { UseShellExecute = false, CreateNoWindow = true })!)
        {
            try
            {
                using (var owner = new ProcessOwnership()) owner.Assign(child);
                await child.WaitForExitAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token);
                if (!child.HasExited) throw new Exception("Owned child survived Job Object close");
            }
            finally { if (!child.HasExited) child.Kill(true); }
        }
        string root = Path.Combine(Path.GetTempPath(), "dvr-win32-test-" + Guid.NewGuid());
        Directory.CreateDirectory(root);
        try
        {
            await using var queue = new RenderQueue(new NeverRender());
            await using var bridge = new Bridge(root, queue, _ => Task.FromResult(false), () => false, () => root, _ => { });
            await using var server = new PipeServer(bridge, PipeAddress.Current);
            server.Start();
            string id = Protocol.ExtensionId(Path.Combine(bundle, "ChromiumExtension", "manifest.json"));
            var info = new ProcessStartInfo(Path.Combine(bundle, "DropViewRender.NativeHost.exe"))
            { UseShellExecute = false, CreateNoWindow = true, RedirectStandardInput = true, RedirectStandardOutput = true, RedirectStandardError = true };
            info.ArgumentList.Add("chrome-extension://" + id + "/");
            using var host = Process.Start(info)!;
            try
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromSeconds(15));
                string requestId = Guid.NewGuid().ToString();
                await Protocol.WriteAsync(host.StandardInput.BaseStream, Protocol.Object(("id", requestId), ("protocolVersion", 1),
                    ("operation", "ping"), ("pageURL", "http://127.0.0.1/"), ("text", "Windows native host")), deadline.Token);
                var result = await Protocol.ReadAsync(host.StandardOutput.BaseStream, deadline.Token);
                if (result?["id"]?.GetValue<string>() != requestId || result["ok"]?.GetValue<bool>() != true ||
                    result["transport"]?.GetValue<string>() != Protocol.Transport) throw new Exception("Windows stdio/pipe roundtrip failed");
                host.StandardInput.Close(); await host.WaitForExitAsync(deadline.Token);
                if (host.ExitCode != 0) throw new Exception("Native host did not exit cleanly");
            }
            finally { if (!host.HasExited) host.Kill(true); }
            info.ArgumentList.Clear(); info.ArgumentList.Add("chrome-extension://" + new string('a', 32) + "/");
            using var denied = Process.Start(info)!;
            denied.StandardInput.Close(); await denied.WaitForExitAsync(new CancellationTokenSource(TimeSpan.FromSeconds(10)).Token);
            if (denied.ExitCode != 1 || (await denied.StandardOutput.ReadToEndAsync()).Length != 0) throw new Exception("Unregistered caller accepted");
            Console.WriteLine("PASS: actual Win32 Job Object lifetime + published native host stdio/named-pipe + caller denial");
        }
        finally { Directory.Delete(root, true); }
    }
}
