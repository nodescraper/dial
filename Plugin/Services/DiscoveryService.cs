using System.Text.Json;
using Jellyfin.Data.Enums;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using MediaBrowser.Model.Entities;
using Jellyfin.Database.Implementations.Enums;
using Microsoft.Extensions.Logging;

namespace Dial.Plugin.Services;

/// Builds each user's Discovery feed on the server: new releases from the artists they own, who else the fans of their
/// top artists listen to, and upcoming concerts. Kept on disk; the apps only fetch the finished feed.
public class DiscoveryService
{
    readonly ILibraryManager _library;
    readonly IUserManager _users;
    readonly IUserDataManager _data;
    readonly ILogger<DiscoveryService> _log;
    readonly SemaphoreSlim _running = new(1, 1);
    static readonly JsonSerializerOptions Options = new() { WriteIndented = false };

    const int ArtistLimit = 40;
    static readonly TimeSpan DiscographyAge = TimeSpan.FromDays(3);

    public DiscoveryService(ILibraryManager library, IUserManager users, IUserDataManager data, ILogger<DiscoveryService> log)
    {
        _library = library; _users = users; _data = data; _log = log;
    }

    string Folder
    {
        get
        {
            var path = Path.Combine(DialPlugin.Instance!.DataFolderPath, "data");
            Directory.CreateDirectory(path);
            return path;
        }
    }

    public string? ReadFeed(Guid userId)
    {
        var file = Path.Combine(Folder, $"feed-{userId:N}.json");
        return File.Exists(file) ? File.ReadAllText(file) : null;
    }

    public DateTime? FeedTime(Guid userId)
    {
        var file = Path.Combine(Folder, $"feed-{userId:N}.json");
        return File.Exists(file) ? File.GetLastWriteTimeUtc(file) : null;
    }

    public bool IsRunning => _running.CurrentCount == 0;

    public async Task RefreshAllAsync(IProgress<double>? progress, CancellationToken ct)
    {
        var all = _users.GetUsers().ToList();
        for (var i = 0; i < all.Count; i++)
        {
            await RefreshAsync(all[i].Id, ct);
            progress?.Report(100.0 * (i + 1) / all.Count);
        }
    }

    public async Task RefreshAsync(Guid userId, CancellationToken ct)
    {
        if (!await _running.WaitAsync(0, ct)) return;
        try
        {
            var user = _users.GetUserById(userId);
            if (user == null) return;
            var config = DialPlugin.Instance!.Configuration;
            var feed = new Feed { ConcertsEnabled = config.ConcertsEnabled && !string.IsNullOrWhiteSpace(config.TicketmasterKey) };

            var artists = TopArtists(user);
            var owned = OwnedAlbums();
            _log.LogInformation("Dial discovery for {User}: {Count} artists", user.Username, artists.Count);

            // New releases
            var all = new List<Pick>();
            var upcoming = new List<Pick>();
            foreach (var artist in artists)
            {
                ct.ThrowIfCancellationRequested();
                foreach (var release in await Discography(artist.Mbid))
                {
                    var key = Web.Normalize(artist.Name) + "|" + Web.Normalize(release.Title);
                    if (owned.Contains(key)) continue;
                    var age = AgeInDays(release);
                    // Not out yet, but with an exact date: the calendar and "coming soon".
                    if (age is < 0 and >= -200 && release.Date is { Length: >= 10 } && release.Kind is "album" or "ep" or "single")
                        upcoming.Add(new Pick { Kind = "album", Mbid = release.Id, Title = release.Title, Artist = artist.Name,
                                                ArtistMbid = artist.Mbid, Year = release.Year, ReleaseDate = release.Date });
                    if (age is null or < 0) continue;
                    var fresh = release.Kind switch { "album" or "ep" => age <= 150, "single" => age <= 60, _ => false };
                    if (!fresh) continue;
                    all.Add(new Pick { Kind = "album", Mbid = release.Id, Title = release.Title, Artist = artist.Name,
                                       ArtistMbid = artist.Mbid, Year = release.Year, ReleaseDate = release.Date });
                }
            }
            feed.Fresh = all.OrderByDescending(p => p.ReleaseDate ?? p.Year?.ToString() ?? "").ToList();
            feed.Upcoming = upcoming.OrderBy(p => p.ReleaseDate).ToList();
            feed.Artists = artists.Select(a => new ArtistRef { Name = a.Name, Mbid = a.Mbid }).ToList();

            // Fans of your top artists also play
            var used = artists.Select(a => a.Mbid).ToHashSet();
            var groups = new List<(string Seed, List<Pick> Picks)>();
            foreach (var seed in artists.Take(3))
            {
                var picks = new List<Pick>();
                foreach (var s in await SimilarArtists(seed.Mbid))
                {
                    if (!used.Add(s.Mbid)) continue;
                    picks.Add(new Pick { Kind = "artist", Mbid = s.Mbid, Title = s.Name });
                    if (picks.Count >= 12) break;
                }
                if (picks.Count > 0) groups.Add((seed.Name, picks));
            }
            var photos = await Photos(groups.SelectMany(g => g.Picks.Select(p => p.Mbid)));
            foreach (var (seed, picks) in groups)
            {
                foreach (var p in picks) if (photos.TryGetValue(p.Mbid, out var url)) p.Image = url;
                feed.Fans.Add(new FanGroup { SeedName = seed, Picks = picks });
            }

            // Concerts
            if (feed.ConcertsEnabled)
                feed.Concerts = await Concerts(artists.Take(25).Select(a => a.Name).ToList(), config, ct);

            feed.GeneratedAt = DateTime.UtcNow;
            File.WriteAllText(Path.Combine(Folder, $"feed-{userId:N}.json"), JsonSerializer.Serialize(feed, Options));
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { _log.LogError(e, "Dial discovery failed"); }
        finally { _running.Release(); }
    }

    // MARK: Library

    record LibArtist(string Name, string Mbid);

    List<LibArtist> TopArtists(Jellyfin.Database.Implementations.Entities.User user)
    {
        var weight = new Dictionary<string, double>();
        var songs = _library.GetItemList(new InternalItemsQuery(user)
        {
            IncludeItemTypes = new[] { BaseItemKind.Audio },
            OrderBy = new[] { (ItemSortBy.PlayCount, SortOrder.Descending) },
            IsPlayed = true,
            Limit = 600,
            Recursive = true,
        });
        foreach (var song in songs)
        {
            var audio = song as Audio;
            var name = audio?.AlbumArtists?.FirstOrDefault() ?? audio?.Artists?.FirstOrDefault();
            if (string.IsNullOrWhiteSpace(name)) continue;
            var plays = _data.GetUserData(user, song)?.PlayCount ?? 1;
            weight[name] = weight.GetValueOrDefault(name) + Math.Min(Math.Max(plays, 1), 30);
        }
        var result = new List<LibArtist>();
        var seen = new HashSet<string>();
        foreach (var name in weight.OrderByDescending(w => w.Value).Select(w => w.Key))
        {
            if (result.Count >= ArtistLimit) break;
            var mbid = MbidFor(name);
            if (mbid != null && seen.Add(mbid)) result.Add(new LibArtist(name, mbid));
        }
        if (result.Count < 10)
        {
            var albumArtists = _library.GetAlbumArtists(new InternalItemsQuery { Recursive = true });
            foreach (var (item, _) in albumArtists.Items)
            {
                if (result.Count >= ArtistLimit) break;
                if (item.ProviderIds.TryGetValue("MusicBrainzArtist", out var mbid) && seen.Add(mbid))
                    result.Add(new LibArtist(item.Name, mbid));
            }
        }
        return result;
    }

    string? MbidFor(string name)
    {
        try
        {
            var artist = _library.GetArtist(name);
            return artist.ProviderIds.TryGetValue("MusicBrainzArtist", out var id) ? id : null;
        }
        catch { return null; }
    }

    HashSet<string> OwnedAlbums()
    {
        var set = new HashSet<string>();
        var albums = _library.GetItemList(new InternalItemsQuery
        {
            IncludeItemTypes = new[] { BaseItemKind.MusicAlbum },
            Recursive = true,
        });
        foreach (var album in albums)
        {
            var artists = (album as MusicAlbum)?.AlbumArtists ?? (IReadOnlyList<string>)Array.Empty<string>();
            foreach (var a in artists) set.Add(Web.Normalize(a) + "|" + Web.Normalize(album.Name));
        }
        return set;
    }

    // MARK: Discographies (MusicBrainz)

    async Task<List<Release>> Discography(string mbid)
    {
        var file = Path.Combine(Folder, $"disco-{mbid}.json");
        if (File.Exists(file) && DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < DiscographyAge)
            return JsonSerializer.Deserialize<List<Release>>(File.ReadAllText(file)) ?? new();
        var releases = new List<Release>();
        for (var offset = 0; offset < 300; offset += 100)
        {
            using var doc = await Web.Json($"https://musicbrainz.org/ws/2/release-group?artist={mbid}&limit=100&offset={offset}&fmt=json", true);
            if (doc == null) break;
            var root = doc.RootElement;
            foreach (var g in root.GetProperty("release-groups").EnumerateArray())
            {
                var secondary = g.TryGetProperty("secondary-types", out var st)
                    ? st.EnumerateArray().Select(x => x.GetString()?.ToLowerInvariant() ?? "").ToHashSet() : new HashSet<string>();
                if (secondary.Overlaps(new[] { "interview", "audiobook", "spokenword", "dj-mix", "demo" })) continue;
                var primary = g.TryGetProperty("primary-type", out var pt) ? pt.GetString()?.ToLowerInvariant() : null;
                var kind = secondary.Contains("compilation") ? "compilation" : secondary.Contains("live") ? "live"
                    : primary switch { "album" => "album", "ep" => "ep", "single" => "single", _ => "other" };
                var date = g.TryGetProperty("first-release-date", out var fd) ? fd.GetString() : null;
                int? year = date is { Length: >= 4 } && int.TryParse(date[..4], out var y) ? y : null;
                releases.Add(new Release { Id = g.GetProperty("id").GetString()!, Title = g.GetProperty("title").GetString() ?? "",
                                           Kind = kind, Date = date, Year = year });
            }
            if (offset + 100 >= root.GetProperty("release-group-count").GetInt32()) break;
        }
        if (releases.Count > 0) File.WriteAllText(file, JsonSerializer.Serialize(releases));
        else if (File.Exists(file)) return JsonSerializer.Deserialize<List<Release>>(File.ReadAllText(file)) ?? new();
        return releases;
    }

    static int? AgeInDays(Release r)
    {
        var d = r.Date;
        if (d is { Length: >= 7 })
        {
            var text = d.Length >= 10 ? d[..10] : d[..7] + "-01";
            if (DateTime.TryParse(text, null, System.Globalization.DateTimeStyles.None, out var parsed))
                return (int)(DateTime.Today - parsed).TotalDays;
            return null;
        }
        return r.Year is { } y ? (y >= DateTime.Today.Year ? 0 : 10_000) : null;
    }

    // MARK: Similar artists (ListenBrainz)

    record Similar(string Mbid, string Name);

    async Task<List<Similar>> SimilarArtists(string mbid)
    {
        var file = Path.Combine(Folder, $"similar-{mbid}.json");
        if (File.Exists(file) && DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < TimeSpan.FromDays(7))
            return JsonSerializer.Deserialize<List<Similar>>(File.ReadAllText(file)) ?? new();
        const string algo = "session_based_days_7500_session_300_contribution_5_threshold_10_limit_100_filter_True_skip_30";
        using var doc = await Web.Json($"https://labs.api.listenbrainz.org/similar-artists/json?artist_mbids={mbid}&algorithm={algo}");
        if (doc == null || doc.RootElement.ValueKind != JsonValueKind.Array) return new();
        var rows = doc.RootElement.EnumerateArray()
            .Where(r => r.TryGetProperty("artist_mbid", out _) && r.GetProperty("artist_mbid").GetString() != mbid)
            .OrderByDescending(r => r.TryGetProperty("score", out var s) && s.ValueKind == JsonValueKind.Number ? s.GetDouble() : 0)
            .Select(r => new Similar(r.GetProperty("artist_mbid").GetString()!, r.GetProperty("name").GetString() ?? ""))
            .ToList();
        if (rows.Count > 0) File.WriteAllText(file, JsonSerializer.Serialize(rows));
        return rows;
    }

    // MARK: Photos (Wikidata)

    async Task<Dictionary<string, string>> Photos(IEnumerable<string> mbids)
    {
        var file = Path.Combine(Folder, "photos.json");
        var known = File.Exists(file) ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(file)) ?? new() : new();
        var missing = mbids.Distinct().Where(m => !known.ContainsKey(m)).ToList();
        foreach (var chunk in missing.Chunk(60))
        {
            var values = string.Join(" ", chunk.Select(m => $"\"{m}\""));
            var query = $"SELECT ?mbid ?image WHERE {{ VALUES ?mbid {{ {values} }} ?item wdt:P434 ?mbid . ?item wdt:P18 ?image . }}";
            using var doc = await Web.Json("https://query.wikidata.org/sparql?format=json&query=" + Uri.EscapeDataString(query));
            if (doc == null) continue;
            var answered = new HashSet<string>();
            foreach (var row in doc.RootElement.GetProperty("results").GetProperty("bindings").EnumerateArray())
            {
                var mbid = row.GetProperty("mbid").GetProperty("value").GetString()!;
                var image = row.GetProperty("image").GetProperty("value").GetString()!;
                if (!answered.Add(mbid)) continue;
                var name = Uri.UnescapeDataString(image.Split('/').Last()).Replace(' ', '_');
                known[mbid] = "https://commons.wikimedia.org/wiki/Special:FilePath/" + Uri.EscapeDataString(name) + "?width=320";
            }
            foreach (var m in chunk) if (!answered.Contains(m)) known[m] = "";
        }
        File.WriteAllText(file, JsonSerializer.Serialize(known));
        return known.Where(k => k.Value != "").ToDictionary(k => k.Key, k => k.Value);
    }

    // MARK: Concerts (Ticketmaster)

    async Task<List<Concert>> Concerts(List<string> names, PluginConfiguration config, CancellationToken ct)
    {
        var file = Path.Combine(Folder, "attractions.json");
        var ids = File.Exists(file) && DateTime.UtcNow - File.GetLastWriteTimeUtc(file) < TimeSpan.FromDays(30)
            ? JsonSerializer.Deserialize<Dictionary<string, string>>(File.ReadAllText(file)) ?? new() : new();
        var key = Uri.EscapeDataString(config.TicketmasterKey.Trim());
        var country = config.CountryCode.Trim().ToUpperInvariant();
        var concerts = new List<Concert>();
        foreach (var name in names)
        {
            ct.ThrowIfCancellationRequested();
            var norm = Web.Normalize(name);
            if (!ids.TryGetValue(norm, out var id))
            {
                using var a = await Web.Json($"https://app.ticketmaster.com/discovery/v2/attractions.json?apikey={key}&keyword={Uri.EscapeDataString(name)}&classificationName=music&size=8");
                if (a == null) { await Task.Delay(250, ct); continue; }
                id = "";
                if (a.RootElement.TryGetProperty("_embedded", out var emb) && emb.TryGetProperty("attractions", out var list))
                    foreach (var at in list.EnumerateArray())
                        if (Web.Normalize(at.GetProperty("name").GetString()) == norm) { id = at.GetProperty("id").GetString() ?? ""; break; }
                ids[norm] = id;
                await Task.Delay(250, ct);
            }
            if (id == "") continue;
            var url = $"https://app.ticketmaster.com/discovery/v2/events.json?apikey={key}&attractionId={id}&size=5&sort=date,asc"
                      + (country.Length == 2 ? $"&countryCode={country}" : "");
            using var e = await Web.Json(url);
            if (e != null && e.RootElement.TryGetProperty("_embedded", out var em) && em.TryGetProperty("events", out var events))
            {
                foreach (var ev in events.EnumerateArray())
                {
                    try
                    {
                        var venue = ev.TryGetProperty("_embedded", out var ee) && ee.TryGetProperty("venues", out var vs) && vs.GetArrayLength() > 0 ? vs[0] : (JsonElement?)null;
                        string? image = null; var best = int.MaxValue;
                        if (ev.TryGetProperty("images", out var imgs))
                            foreach (var im in imgs.EnumerateArray())
                            {
                                var wide = im.TryGetProperty("ratio", out var r) && r.GetString() == "16_9";
                                var w = im.TryGetProperty("width", out var wv) ? wv.GetInt32() : 0;
                                var score = Math.Abs(w - 640) + (wide ? 0 : 100000);
                                if (score < best) { best = score; image = im.GetProperty("url").GetString(); }
                            }
                        concerts.Add(new Concert
                        {
                            Id = ev.GetProperty("id").GetString()!, Artist = name, Name = ev.GetProperty("name").GetString() ?? "",
                            Date = ev.GetProperty("dates").GetProperty("start").GetProperty("localDate").GetString()!,
                            Venue = venue?.TryGetProperty("name", out var vn) == true ? vn.GetString() ?? "" : "",
                            City = venue?.TryGetProperty("city", out var vc) == true && vc.TryGetProperty("name", out var cn) ? cn.GetString() ?? "" : "",
                            Url = ev.GetProperty("url").GetString() ?? "", Image = image,
                        });
                    }
                    catch { }
                }
            }
            await Task.Delay(250, ct);
        }
        File.WriteAllText(file, JsonSerializer.Serialize(ids));
        return concerts.GroupBy(c => c.Id).Select(g => g.First()).OrderBy(c => c.Date).ToList();
    }
}
