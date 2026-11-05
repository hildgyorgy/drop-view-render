using DropViewRender;
using System.IO.Pipes;
using System.Runtime.InteropServices;
using System.Text;

internal static class Program
{
    public static async Task<int> Main(string[] args)
    {
        try
        {
            if (!OperatingSystem.IsWindows()) return 1;
            string expected = "chrome-extension://" + Protocol.ExtensionId(Path.Combine(AppContext.BaseDirectory, "ChromiumExtension", "manifest.json")) + "/";
            if (args.Length == 0 || args[0] != expected) return 1;
            await using var pipe = new NamedPipeClientStream(".", PipeAddress.Current, PipeDirection.InOut, PipeOptions.Asynchronous);
            try { await pipe.ConnectAsync(250); }
            catch (TimeoutException)
            {
                StartIndependentTray(Path.Combine(AppContext.BaseDirectory, "DropViewRender.Tray.exe"));
                await pipe.ConnectAsync(10000);
            }
            var input = Console.OpenStandardInput(); var output = Console.OpenStandardOutput();
            while (await Protocol.ReadAsync(input) is { } message)
            {
                using var deadline = new CancellationTokenSource(TimeSpan.FromMinutes(11));
                await Protocol.WriteAsync(pipe, message, deadline.Token);
                var response = await Protocol.ReadAsync(pipe, deadline.Token) ?? throw new IOException();
                await Protocol.WriteAsync(output, response, deadline.Token);
            }
            return 0;
        }
        catch (Exception) { Console.Error.WriteLine("Drop & View Render: native connection unavailable. Open the tray app and retry."); return 1; }
    }
    private static void StartIndependentTray(string path)
    {
        // Escape the browser's native-host job: accepted renders belong to the
        // user's tray app and must survive a closed extension port/browser.
        var startup = new StartupInfo { Size = Marshal.SizeOf<StartupInfo>() };
        if (!CreateProcess(path, new StringBuilder('"' + path + '"'), IntPtr.Zero, IntPtr.Zero, false,
            0x01000000 | 0x00000008, IntPtr.Zero, Path.GetDirectoryName(path), ref startup, out var process))
            throw new IOException("Open the tray app manually.");
        CloseHandle(process.Thread); CloseHandle(process.Process);
    }
    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    private struct StartupInfo
    {
        public int Size; public string? Reserved, Desktop, Title;
        public int X, Y, XSize, YSize, XChars, YChars, Fill, Flags;
        public short Show, ReservedSize; public IntPtr ReservedPointer, Input, Output, Error;
    }
    [StructLayout(LayoutKind.Sequential)] private struct ProcessInfo { public IntPtr Process, Thread; public int ProcessId, ThreadId; }
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true, EntryPoint = "CreateProcessW")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool CreateProcess(string app, StringBuilder command, IntPtr processSecurity, IntPtr threadSecurity,
        bool inherit, uint flags, IntPtr environment, string? directory, ref StartupInfo startup, out ProcessInfo process);
    [DllImport("kernel32.dll")][return: MarshalAs(UnmanagedType.Bool)] private static extern bool CloseHandle(IntPtr handle);
}
