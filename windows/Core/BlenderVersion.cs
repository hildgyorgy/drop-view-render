using System.Text.RegularExpressions;

namespace DropViewRender;

public static class BlenderVersion
{
    // 5.3 is preferred; keep the previously supported LTS family usable.
    public static bool IsSupported(string output)
    {
        string firstLine = output.Split('\n')[0];
        var match = Regex.Match(firstLine, @"^Blender (5\.[23]\.\d+)(?:\s|$)", RegexOptions.CultureInvariant);
        return match.Success && Version.TryParse(match.Groups[1].Value, out var version) &&
               version >= new Version(5, 2, 3) &&
               !Regex.IsMatch(firstLine, "alpha|beta|candidate", RegexOptions.IgnoreCase | RegexOptions.CultureInvariant);
    }
}
