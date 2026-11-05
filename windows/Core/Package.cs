using System.Buffers.Binary;
using System.Text;
using System.Text.Json.Nodes;
using System.Text.RegularExpressions;

namespace DropViewRender;

public sealed record Package(string FileName, int Width, int Height, int Samples, int Bounces, int TransmissionBounces)
{
    public const long MaximumBytes = 2L * 1024 * 1024 * 1024;
    public static bool SafeName(string name) => name.Length > 0 && Encoding.UTF8.GetByteCount(name) <= 255 &&
        name is not "." and not ".." && !name.Any(c => char.IsControl(c) || "<>:\"/\\|?*".Contains(c)) &&
        !name.EndsWith(' ') && !name.EndsWith('.');
    private static int Setting(JsonObject value, string field, int maximum)
    {
        var number = Protocol.Integer(value, field);
        if (number < 1 || number > maximum) throw new BridgeException("invalid_render_settings");
        return (int)number;
    }
    public static async Task<Package> ReadAsync(string path, CancellationToken cancellation = default)
    {
        await using var input = new FileStream(path, FileMode.Open, FileAccess.Read, FileShare.Read, 65536, true);
        if (input.Length < 24 || input.Length > MaximumBytes) throw new BridgeException("invalid_package_size");
        byte[] header = new byte[12];
        await input.ReadExactlyAsync(header, cancellation);
        if (!header.AsSpan(0, 8).SequenceEqual("DVRENDER"u8)) throw new BridgeException("invalid_package");
        uint count = BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8));
        if (count == 0 || count > 4 * 1024 * 1024 || count > input.Length - 12) throw new BridgeException("invalid_manifest");
        var bytes = new byte[count];
        await input.ReadExactlyAsync(bytes, cancellation);
        var json = JsonNode.Parse(bytes) as JsonObject ?? throw new BridgeException("invalid_manifest");
        if (Protocol.Integer(json, "version") != 1 || json.ContainsKey("workbench") || json.ContainsKey("resolvedModel") ||
            json["viewSession"] is not JsonObject || json["producer"] is not JsonObject ||
            json["lengths"] is not JsonArray lengths || lengths.Count is < 1 or > 2)
            throw new BridgeException("unsupported_manifest");
        string name = Protocol.Text(json, "fileName", 255);
        if (!SafeName(name) || !name.EndsWith(".glb", StringComparison.OrdinalIgnoreCase)) throw new BridgeException("invalid_filename");
        long sum = 12 + count;
        var sizes = new List<long>();
        foreach (var item in lengths)
        {
            if (item is not JsonValue v || !v.TryGetValue<long>(out var size) || size <= 0 || size > input.Length - sum)
                throw new BridgeException("length_mismatch");
            sum += size; sizes.Add(size);
        }
        if (sum != input.Length || sizes[0] < 12) throw new BridgeException("length_mismatch");
        await input.ReadExactlyAsync(header, cancellation);
        if (!header.AsSpan(0, 4).SequenceEqual("glTF"u8) || BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(4)) != 2 ||
            BinaryPrimitives.ReadUInt32LittleEndian(header.AsSpan(8)) != sizes[0]) throw new BridgeException("invalid_glb");
        if (json["environment"] is JsonObject environment)
        {
            var hdriName = Protocol.Text(environment, "name", 255);
            if (sizes.Count != 2 || Protocol.Integer(environment, "resource") != 1 || sizes[1] > 256L * 1024 * 1024 ||
                !SafeName(hdriName) || !hdriName.EndsWith(".hdr", StringComparison.OrdinalIgnoreCase)) throw new BridgeException("invalid_environment");
            input.Position = 12 + count + sizes[0];
            var hdri = new byte[(int)Math.Min(sizes[1], 32768)];
            await input.ReadExactlyAsync(hdri, cancellation);
            string text = Encoding.UTF8.GetString(hdri);
            var match = Regex.Match(text, @"[+-]Y\s+(\d+)\s+[+-]X\s+(\d+)", RegexOptions.CultureInvariant);
            if (!(text.StartsWith("#?RADIANCE", StringComparison.Ordinal) || text.StartsWith("#?RGBE", StringComparison.Ordinal)) ||
                !match.Success || !long.TryParse(match.Groups[1].Value, out long h) || !long.TryParse(match.Groups[2].Value, out long w) ||
                w < 1 || h < 1 || w > 32_000_000 || h > 32_000_000 / w) throw new BridgeException("invalid_environment");
        }
        else if (json["environment"] != null || sizes.Count != 1) throw new BridgeException("invalid_environment");
        int width = 3456, height = 2168, samples = 64, bounces = 6, transmission = 10;
        if (json["renderSize"] is JsonObject dimensions)
        { width = Setting(dimensions, "width", 16384); height = Setting(dimensions, "height", 16384); }
        else if (json["renderSize"] != null) throw new BridgeException("invalid_render_settings");
        if (json["renderJob"] is JsonObject quality)
        { samples = Setting(quality, "samples", 100000); bounces = Setting(quality, "bounces", 64); transmission = Setting(quality, "transmissiveBounces", 64); }
        else if (json["renderJob"] != null) throw new BridgeException("invalid_render_settings");
        return new Package(name, width, height, samples, bounces, transmission);
    }
}
