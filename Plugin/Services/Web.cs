using System.Globalization;
using System.Text;
using System.Text.Json;
using System.Text.RegularExpressions;

namespace Dial.Plugin.Services;

/// Polite access to the open music databases: MusicBrainz allows one request a second.
public static class Web
{
    public static readonly HttpClient Client = Make();
    static readonly SemaphoreSlim MbLock = new(1, 1);
    static DateTime lastMb = DateTime.MinValue;

    static HttpClient Make()
    {
        var c = new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
        c.DefaultRequestHeaders.UserAgent.ParseAdd("DialJellyfinPlugin/0.1 (https://github.com/nodescraper)");
        return c;
    }

    public static async Task<JsonDocument?> Json(string url, bool musicBrainz = false)
    {
        try
        {
            if (musicBrainz)
            {
                await MbLock.WaitAsync();
                try
                {
                    var wait = TimeSpan.FromMilliseconds(1100) - (DateTime.UtcNow - lastMb);
                    if (wait > TimeSpan.Zero) await Task.Delay(wait);
                    lastMb = DateTime.UtcNow;
                }
                finally { MbLock.Release(); }
            }
            using var response = await Client.GetAsync(url);
            if (!response.IsSuccessStatusCode) return null;
            return await JsonDocument.ParseAsync(await response.Content.ReadAsStreamAsync());
        }
        catch { return null; }
    }

    /// Lowercase, no accents, no punctuation or bracketed extras like "(Deluxe Edition)".
    public static string Normalize(string? text)
    {
        if (string.IsNullOrWhiteSpace(text)) return "";
        var t = Regex.Replace(text, @"[\(\[][^\)\]]*[\)\]]", " ");
        var d = t.Normalize(NormalizationForm.FormD);
        var sb = new StringBuilder();
        foreach (var ch in d)
        {
            if (CharUnicodeInfo.GetUnicodeCategory(ch) == UnicodeCategory.NonSpacingMark) continue;
            sb.Append(char.IsLetterOrDigit(ch) ? char.ToLowerInvariant(ch) : ' ');
        }
        return Regex.Replace(sb.ToString(), @"\s+", " ").Trim();
    }
}
