using System.Text.Json.Serialization;

namespace Dial.Plugin.Services;

// These match the apps' own types, so a feed can be decoded as it is.
public class Pick
{
    [JsonPropertyName("kind")] public string Kind { get; set; } = "album";
    [JsonPropertyName("mbid")] public string Mbid { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("artist")] public string? Artist { get; set; }
    [JsonPropertyName("artistMbid")] public string? ArtistMbid { get; set; }
    [JsonPropertyName("year")] public int? Year { get; set; }
    [JsonPropertyName("tags")] public List<string> Tags { get; set; } = new();
    [JsonPropertyName("image")] public string? Image { get; set; }
    [JsonPropertyName("releaseDate")] public string? ReleaseDate { get; set; }
}

public class ArtistRef
{
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("mbid")] public string Mbid { get; set; } = "";
}

public class FanGroup
{
    [JsonPropertyName("seedName")] public string SeedName { get; set; } = "";
    [JsonPropertyName("picks")] public List<Pick> Picks { get; set; } = new();
}

public class Concert
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("artist")] public string Artist { get; set; } = "";
    [JsonPropertyName("name")] public string Name { get; set; } = "";
    [JsonPropertyName("date")] public string Date { get; set; } = "";
    [JsonPropertyName("venue")] public string Venue { get; set; } = "";
    [JsonPropertyName("city")] public string City { get; set; } = "";
    [JsonPropertyName("url")] public string Url { get; set; } = "";
    [JsonPropertyName("image")] public string? Image { get; set; }
}

public class Feed
{
    [JsonPropertyName("fresh")] public List<Pick> Fresh { get; set; } = new();
    /// Releases with an exact date still ahead (within about six months), soonest first.
    [JsonPropertyName("upcoming")] public List<Pick> Upcoming { get; set; } = new();
    /// The artists you play most, in order (the apps rank the news by them).
    [JsonPropertyName("artists")] public List<ArtistRef> Artists { get; set; } = new();
    [JsonPropertyName("fans")] public List<FanGroup> Fans { get; set; } = new();
    [JsonPropertyName("concerts")] public List<Concert> Concerts { get; set; } = new();
    [JsonPropertyName("generatedAt")] public DateTime GeneratedAt { get; set; }
    [JsonPropertyName("concertsEnabled")] public bool ConcertsEnabled { get; set; }
}

public class Release
{
    public string Id { get; set; } = "";
    public string Title { get; set; } = "";
    public int? Year { get; set; }
    public string Kind { get; set; } = "other";
    public string? Date { get; set; }
}
