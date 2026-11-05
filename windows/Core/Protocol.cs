using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DropViewRender;

public sealed class BridgeException(string code, int status = 400) : Exception(code)
{
    public int Status { get; } = status;
}

public static partial class Protocol
{
    public const int MaximumFrame = 100_000;
    public const string Transport = "chromium-native-messaging";
    public static JsonObject Object(params (string Key, object? Value)[] values)
    {
        var result = new JsonObject();
        foreach (var (key, value) in values) result[key] = JsonSerializer.SerializeToNode(value);
        return result;
    }
    public static string Text(JsonObject value, string field, int limit = 4096) =>
        value[field] is JsonValue node && node.TryGetValue<string>(out var text) && text.Length <= limit
            ? text : throw new BridgeException("invalid_message");
    public static long Integer(JsonObject value, string field)
    {
        if (value[field] is JsonValue node)
        {
            if (node.TryGetValue<long>(out var number)) return number;
            if (node.TryGetValue<int>(out var integer)) return integer;
        }
        throw new BridgeException("invalid_message");
    }
    public static string Uuid(JsonObject value, string field)
    {
        var id = Text(value, field, 36);
        if (!Guid.TryParseExact(id, "D", out _)) throw new BridgeException("invalid_id");
        return id;
    }
    public static string Origin(string page)
    {
        if (!Uri.TryCreate(page, UriKind.Absolute, out var uri) || uri.UserInfo.Length != 0)
            throw new BridgeException("origin_not_allowed", 403);
        bool allowed = uri.Scheme == "https" && uri.Host == "hildgyorgy.github.io" && uri.IsDefaultPort &&
            (uri.AbsolutePath == "/drop-3d-view" || uri.AbsolutePath.StartsWith("/drop-3d-view/", StringComparison.Ordinal));
        allowed |= uri.Scheme == "http" && (uri.Host == "localhost" || uri.Host == "127.0.0.1");
        if (!allowed) throw new BridgeException("origin_not_allowed", 403);
        return uri.GetLeftPart(UriPartial.Authority);
    }
    public static string ExtensionId(string manifest)
    {
        var json = JsonNode.Parse(File.ReadAllText(manifest))!.AsObject();
        var digest = SHA256.HashData(Convert.FromBase64String(Text(json, "key")));
        return string.Concat(digest.Take(16).Select(b => $"{(char)('a' + (b >> 4))}{(char)('a' + (b & 15))}"));
    }
    public static JsonObject Reply(string id, JsonObject data) => Object(
        ("protocolVersion", 1), ("id", id), ("ok", true), ("transport", Transport), ("data", data));
    public static JsonObject Failure(string id, string code, int status = 400) => Object(
        ("protocolVersion", 1), ("id", id), ("ok", false), ("error", code), ("status", status));

    // No whole-package JSON: every stdio and pipe frame is bounded before allocation.
    public static async Task<JsonObject?> ReadAsync(Stream input, CancellationToken cancellation = default)
    {
        var header = new byte[4];
        int first = await input.ReadAsync(header.AsMemory(0, 1), cancellation);
        if (first == 0) return null;
        await input.ReadExactlyAsync(header.AsMemory(1), cancellation);
        uint count = BinaryPrimitives.ReadUInt32LittleEndian(header);
        if (count == 0 || count > MaximumFrame) throw new BridgeException("invalid_message");
        var bytes = new byte[count];
        await input.ReadExactlyAsync(bytes, cancellation);
        return JsonNode.Parse(bytes, documentOptions: new JsonDocumentOptions { MaxDepth = 32 }) as JsonObject
            ?? throw new BridgeException("invalid_message");
    }
    public static async Task WriteAsync(Stream output, JsonObject value, CancellationToken cancellation = default)
    {
        byte[] bytes = JsonSerializer.SerializeToUtf8Bytes(value);
        if (bytes.Length > MaximumFrame) throw new BridgeException("invalid_message");
        var header = new byte[4];
        BinaryPrimitives.WriteUInt32LittleEndian(header, (uint)bytes.Length);
        await output.WriteAsync(header, cancellation);
        await output.WriteAsync(bytes, cancellation);
        await output.FlushAsync(cancellation);
    }
    [GeneratedRegex("^[A-Fa-f0-9-]{72}$", RegexOptions.CultureInvariant)]
    public static partial Regex TokenPattern();
    public static string Digest(ReadOnlySpan<byte> bytes) => Convert.ToHexStringLower(SHA256.HashData(bytes));
}
