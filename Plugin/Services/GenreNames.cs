using System.Text.RegularExpressions;

namespace Dial.Plugin.Services;

/// Folds the many ways genres are tagged into a few families ("Trap Latino" is Latin, "Pop Rap" is Hip-Hop).
public static class GenreNames
{
    record Rule(string Family, string[]? Contains = null, string[]? Words = null, string[]? Whole = null);

    static readonly Rule[] Rules =
    {
        new("Latin", new[] { "latin", "reggaeton", "urbano", "bachata", "salsa", "cumbia", "dembow", "corrido", "regionalmexican", "banda", "norteno", "merengue", "flamenco", "mariachi", "vallenato", "perreo", "tropical", "mexican", "reguet", "sertanejo", "bossanova" }, new[] { "mpb", "tejano" }),
        new("K-Pop", new[] { "kpop", "korean", "jpop", "japanese" }),
        new("Afrobeats", new[] { "afrobeat", "afropop", "amapiano", "highlife", "afroswing", "naija" }),
        new("Reggae", new[] { "reggae", "dancehall" }, new[] { "ska", "dub" }),
        new("Hip-Hop", new[] { "hiphop", "drill", "grime", "boombap", "gangsta", "mumble" }, new[] { "rap", "trap", "hh" }),
        new("R&B", new[] { "rhythmandblues", "contemporaryrb", "alternativerb" }, null, new[] { "rb", "rnb", "randb" }),
        new("Soul", new[] { "soul", "motown" }),
        new("Funk", new[] { "funk" }),
        new("Disco", new[] { "disco" }),
        new("Metal", new[] { "metal" }),
        new("Punk", new[] { "punk", "hardcore" }, new[] { "emo" }),
        new("Indie", new[] { "indie", "shoegaze", "dreampop" }),
        new("Alternative", new[] { "alternative", "grunge", "newwave", "postrock" }, new[] { "alt" }),
        new("Rock", new[] { "rock", "psychedelic" }),
        new("Electronic", new[] { "electro", "techno", "trance", "dubstep", "synth", "drumandbass", "ambient", "downtempo", "idm", "triphop", "chillout", "lofi" }, new[] { "edm", "dnb" }),
        new("Dance", new[] { "dance", "house", "club", "garage", "eurodance" }),
        new("Pop", new[] { "pop" }),
        new("Jazz", new[] { "jazz", "swing", "bebop", "bigband" }),
        new("Blues", new[] { "blues" }),
        new("Country", new[] { "country", "bluegrass", "americana" }),
        new("Folk", new[] { "folk", "singersongwriter", "acoustic" }),
        new("Classical", new[] { "classical", "orchestra", "opera", "baroque", "symphon", "chambermusic" }),
        new("Soundtrack", new[] { "soundtrack", "score", "musical" }, new[] { "ost", "film" }),
        new("Gospel", new[] { "gospel", "christian", "worship" }),
    };

    public static List<string> Canonical(string tag)
    {
        var names = new List<string>();
        foreach (var raw in tag.Split(',', ';', '/', '|'))
        {
            var part = raw.Trim();
            if (part.Length == 0) continue;
            var name = FamilyOf(part) ?? part;
            if (!names.Contains(name)) names.Add(name);
        }
        return names;
    }

    public static List<string> Families(IEnumerable<string> tags)
    {
        var seen = new List<string>();
        foreach (var t in tags) foreach (var n in Canonical(t)) if (!seen.Contains(n)) seen.Add(n);
        return seen;
    }

    static string? FamilyOf(string part)
    {
        var lower = part.ToLowerInvariant();
        var squashed = new string(lower.Replace("&", "and").Where(char.IsLetterOrDigit).ToArray());
        var words = Regex.Split(lower.Replace("&", " and "), @"[^\p{L}\p{N}]+").Where(w => w.Length > 0).ToHashSet();
        var whole = lower.Contains('&') ? new string(lower.Where(char.IsLetter).ToArray()) : squashed;
        foreach (var rule in Rules)
        {
            if (rule.Whole != null && (rule.Whole.Contains(whole) || rule.Whole.Contains(squashed))) return rule.Family;
            if (rule.Contains != null && rule.Contains.Any(c => squashed.Contains(c))) return rule.Family;
            if (rule.Words != null && rule.Words.Any(w => words.Contains(w))) return rule.Family;
        }
        return null;
    }
}
