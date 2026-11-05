using System.Diagnostics;
using System.IO.Pipes;
using System.Security.Cryptography;
using System.Security.Principal;
using System.Text;

namespace DropViewRender;

public static class PipeAddress
{
    public static string Current
    {
        get
        {
            string identity = Environment.UserName;
            if (OperatingSystem.IsWindows()) identity = WindowsIdentity.GetCurrent().User!.Value + ":" + Process.GetCurrentProcess().SessionId;
            return "DropViewRender-" + Convert.ToHexStringLower(SHA256.HashData(Encoding.UTF8.GetBytes(identity)))[..24];
        }
    }
}

public sealed class PipeServer(Bridge bridge, string name) : IAsyncDisposable
{
    private readonly CancellationTokenSource stop = new();
    private readonly List<Task> workers = [];
    public void Start()
    {
        // Fixed workers bound the number of clients and simultaneous framed bodies.
        for (int i = 0; i < 4; i++) workers.Add(Task.Run(ListenAsync));
    }
    private async Task ListenAsync()
    {
        while (!stop.IsCancellationRequested)
        {
            await using var pipe = new NamedPipeServerStream(name, PipeDirection.InOut, 4, PipeTransmissionMode.Byte,
                PipeOptions.Asynchronous | PipeOptions.CurrentUserOnly);
            try
            {
                await pipe.WaitForConnectionAsync(stop.Token);
                while (pipe.IsConnected && !stop.IsCancellationRequested)
                {
                    using var deadline = CancellationTokenSource.CreateLinkedTokenSource(stop.Token);
                    deadline.CancelAfter(TimeSpan.FromMinutes(11));
                    var request = await Protocol.ReadAsync(pipe, deadline.Token);
                    if (request == null) break;
                    var response = await bridge.HandleAsync(request, deadline.Token);
                    await Protocol.WriteAsync(pipe, response, deadline.Token);
                }
            }
            catch (Exception error) when (error is IOException or OperationCanceledException or BridgeException or System.Text.Json.JsonException)
            { /* Closing the pipe fails the caller; never log a frame/token. */ }
        }
    }
    public async ValueTask DisposeAsync() { stop.Cancel(); await Task.WhenAll(workers); stop.Dispose(); }
}
