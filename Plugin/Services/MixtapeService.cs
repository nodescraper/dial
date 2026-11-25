using System.Text.Json;
using System.Text.Json.Serialization;
using Jellyfin.Data.Enums;
using Jellyfin.Database.Implementations.Entities;
using MediaBrowser.Common.Configuration;
using MediaBrowser.Controller.Entities;
using MediaBrowser.Controller.Entities.Audio;
using MediaBrowser.Controller.Library;
using Microsoft.Data.Sqlite;
using Microsoft.Extensions.Logging;
using Jellyfin.Database.Implementations.Enums;

namespace Dial.Plugin.Services;

public class Mixtape
{
    [JsonPropertyName("id")] public string Id { get; set; } = "";
    [JsonPropertyName("title")] public string Title { get; set; } = "";
    [JsonPropertyName("subtitle")] public string Subtitle { get; set; } = "";
    [JsonPropertyName("palette")] public List<string> Palette { get; set; } = new();
    [JsonPropertyName("trackIds")] public List<string> TrackIds { get; set; } = new();
    [JsonPropertyName("coverIds")] public List<string> CoverIds { get; set; } = new();
}

public class MixtapeSet
{
    [JsonPropertyName("day")] public string Day { get; set; } = "";
    [JsonPropertyName("mixes")] public List<Mixtape> Mixes { get; set; } = new();
    /// Songs that were in a mixtape, with the day they were last in one: kept a week so they rest.
    [JsonPropertyName("rested")] public Dictionary<string, string> Rested { get; set; } = new();
}

/// Mixtapes made from each user's own listening, for people whose library is music they chose: it brings back what they
/// have not heard in a while next to what they play now. Built once a day on the server, the same on every device.
public class MixtapeService
{
    readonly ILibraryManager _library;
    readonly IUserManager _users;
    readonly IUserDataManager _data;
    readonly IApplicationPaths _paths;
    readonly ILogger<MixtapeService> _log;
    readonly SemaphoreSlim _running = new(1, 1);

    static readonly Dictionary<string, string[]> Palettes = new()
    {
        ["Daily Mix 1"] = new[] { "#7A4FB5", "#C96BFF" }, ["Daily Mix 2"] = new[] { "#1F4D73", "#59BFD9" },
        ["Daily Mix 3"] = new[] { "#99401A", "#F2B24D" }, ["Daily Mix 4"] = new[] { "#26665A", "#99D98C" },
        ["On Repeat"] = new[] { "#C2412D", "#2B1A1A" }, ["Rewind"] = new[] { "#8C3380", "#F28066" },
        ["Deep Cuts"] = new[] { "#333366", "#8C73D9" }, ["Time Capsule"] = new[] { "#80592A", "#D9BF80" },
    };

    public MixtapeService(ILibraryManager library, IUserManager users, IUserDataManager data, IApplicationPaths paths, ILogger<MixtapeService> log)
    {
        _library = library; _users = users; _data = data; _paths = paths; _log = log;
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

    /// True while a set is being built.
    public bool IsRunning => _running.CurrentCount == 0;

    static string Today => DateTime.Now.ToString("yyyy-MM-dd");
    string FileFor(Guid user) => Path.Combine(Folder, $"mixes-{user:N}.json");

    /// The saved set, and whether it is from today.
    public (string? Json, bool Current) Read(Guid user)
    {
        var file = FileFor(user);
        if (!File.Exists(file)) return (null, false);
        var json = File.ReadAllText(file);
        try { return (json, JsonSerializer.Deserialize<MixtapeSet>(json)?.Day == Today); } catch { return (json, false); }
    }

    public async Task RefreshAllAsync(IProgress<double>? progress, CancellationToken ct)
    {
        var all = _users.GetUsers().ToList();
        for (var i = 0; i < all.Count; i++) { await RefreshAsync(all[i].Id, ct); progress?.Report(100.0 * (i + 1) / all.Count); }
    }

    public async Task RefreshAsync(Guid userId, CancellationToken ct)
    {
        if (!await _running.WaitAsync(0, ct)) return;
        try
        {
            var user = _users.GetUserById(userId);
            if (user == null) return;
            var rested = new Dictionary<string, string>();
            var (old, _) = Read(userId);
            if (old != null)
                try { rested = JsonSerializer.Deserialize<MixtapeSet>(old)!.Rested ?? new(); } catch { }
            // Songs from the last week's mixtapes rest, unless there are not enough others to make a mix.
            var cutoff = DateTime.Now.AddDays(-7).ToString("yyyy-MM-dd");
            var avoid = rested.Where(kv => string.CompareOrdinal(kv.Value, cutoff) >= 0).Select(kv => kv.Key).ToHashSet();
            var set = await Task.Run(() => Build(user, avoid), ct);
            foreach (var m in set.Mixes) foreach (var t in m.TrackIds) rested[t] = set.Day;
            set.Rested = rested.Where(kv => string.CompareOrdinal(kv.Value, cutoff) >= 0).ToDictionary(kv => kv.Key, kv => kv.Value);
            File.WriteAllText(FileFor(userId), JsonSerializer.Serialize(set));
            _log.LogInformation("Dial mixtapes for {User}: {Count}", user.Username, set.Mixes.Count);
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { _log.LogError(e, "Dial mixtapes failed"); }
        finally { _running.Release(); }
    }

    // MARK: Listening

    class Listening
    {
        public Dictionary<string, int> Plays = new();
        public Dictionary<string, DateTime> LastPlayed = new();
        public HashSet<string> Favorites = new();
        public HashSet<string> Recent3 = new(), Recent30 = new();
        public List<BaseItem> Played = new(), Favs = new();
        public List<(string Id, int Plays)> Top30 = new();
        /// Every play of the last 180 days, oldest first: the song, when, and how many seconds it was heard.
        public List<(string Id, DateTime At, int Seconds)> History = new();
        /// Songs you keep skipping (most of their plays last a few seconds).
        public HashSet<string> Skipped = new();
        public bool HasHistory;

        public bool IsKnown(string id) => Favorites.Contains(id) || Plays.GetValueOrDefault(id) > 0;
        public bool Heard(string id, int days)
        {
            if (days <= 3 && Recent3.Contains(id)) return true;
            if (days <= 30 && Recent30.Contains(id)) return true;
            return LastPlayed.TryGetValue(id, out var d) && d > DateTime.UtcNow.AddDays(-days);
        }
        public double Weight(string id) => (Math.Min(Plays.GetValueOrDefault(id), 30) / 30.0 + (Favorites.Contains(id) ? 0.5 : 0)) * (Skipped.Contains(id) ? 0.2 : 1.0);
    }

    static string N(Guid id) => id.ToString("N");

    Listening Listen(User user)
    {
        var l = new Listening();
        var songs = _library.GetItemList(new InternalItemsQuery(user)
        {
            IncludeItemTypes = new[] { BaseItemKind.Audio }, IsPlayed = true, Recursive = true, Limit = 600,
            OrderBy = new[] { (ItemSortBy.PlayCount, SortOrder.Descending) },
        });
        var favs = _library.GetItemList(new InternalItemsQuery(user)
        {
            IncludeItemTypes = new[] { BaseItemKind.Audio }, IsFavorite = true, Recursive = true, Limit = 1500,
        });
        l.Played = songs.ToList(); l.Favs = favs.ToList();
        foreach (var item in l.Played.Concat(l.Favs))
        {
            var ud = _data.GetUserData(user, item);
            var id = N(item.Id);
            if (ud == null) continue;
            if (ud.PlayCount > 0) l.Plays[id] = ud.PlayCount;
            if (ud.LastPlayedDate is { } d) l.LastPlayed[id] = d.ToUniversalTime();
            if (ud.IsFavorite) l.Favorites.Add(id);
        }
        // Playback Reporting knows more recent plays than the server's own counters.
        var db = Path.Combine(_paths.DataPath, "playback_reporting.db");
        if (File.Exists(db))
        {
            try
            {
                using var con = new SqliteConnection($"Data Source={db};Mode=ReadOnly");
                con.Open();
                string Q(int days) => $"SELECT ItemId, COUNT(*) FROM PlaybackActivity WHERE UserId = $u AND ItemType = 'Audio' AND DateCreated > $d GROUP BY ItemId ORDER BY 2 DESC";
                List<(string, int)> Rows(int days)
                {
                    using var cmd = con.CreateCommand();
                    cmd.CommandText = Q(days);
                    cmd.Parameters.AddWithValue("$u", N(user.Id));
                    cmd.Parameters.AddWithValue("$d", DateTime.UtcNow.AddDays(-days).ToString("yyyy-MM-dd HH:mm:ss"));
                    var rows = new List<(string, int)>();
                    using var r = cmd.ExecuteReader();
                    while (r.Read()) rows.Add((r.GetString(0), r.GetInt32(1)));
                    return rows;
                }
                foreach (var (id, c) in Rows(90)) l.Plays[id] = Math.Max(l.Plays.GetValueOrDefault(id), c);
                var d30 = Rows(30);
                l.Top30 = d30.Take(60).ToList();
                foreach (var (id, _) in d30) l.Recent30.Add(id);
                foreach (var (id, _) in Rows(3)) l.Recent3.Add(id);
                using (var cmd = con.CreateCommand())
                {
                    cmd.CommandText = "SELECT ItemId, DateCreated, PlayDuration FROM PlaybackActivity WHERE UserId = $u AND ItemType = 'Audio' AND DateCreated > $d ORDER BY DateCreated";
                    cmd.Parameters.AddWithValue("$u", N(user.Id));
                    cmd.Parameters.AddWithValue("$d", DateTime.UtcNow.AddDays(-180).ToString("yyyy-MM-dd HH:mm:ss"));
                    using var r = cmd.ExecuteReader();
                    while (r.Read())
                        if (DateTime.TryParse(r.GetString(1), null, System.Globalization.DateTimeStyles.AssumeUniversal | System.Globalization.DateTimeStyles.AdjustToUniversal, out var at))
                            l.History.Add((r.GetString(0), at, r.IsDBNull(2) ? 0 : r.GetInt32(2)));
                }
                foreach (var g in l.History.GroupBy(h => h.Id))
                {
                    var plays = g.Count();
                    if (plays >= 3 && g.Count(h => h.Seconds < 30) >= plays * 0.6) l.Skipped.Add(g.Key);
                }
                l.HasHistory = true;
            }
            catch (Exception e) { _log.LogWarning(e, "Playback Reporting unreadable"); }
        }
        return l;
    }

    // MARK: Building

    static double Noise(string id, string day, string salt)
    {
        ulong hash = 14695981039346656037UL;
        foreach (var b in System.Text.Encoding.UTF8.GetBytes(salt + day + id)) { hash ^= b; hash *= 1099511628211UL; }
        return (hash % 1000) / 1000.0;
    }

    static string Primary(BaseItem item) => Web.Normalize(PrimaryName(item));

    /// "Post Malone feat. 2 Chainz" is "Post Malone"; "Kanye West & Ye" is kept as the tag has it.
    static string PrimaryName(BaseItem item)
    {
        var a = item as Audio;
        var name = a?.AlbumArtists?.FirstOrDefault() ?? a?.Artists?.FirstOrDefault() ?? "";
        foreach (var m in new[] { " feat. ", " feat ", " ft. ", " ft ", " featuring ", " with ", " vs. ", " vs " })
        {
            var i = name.IndexOf(m, StringComparison.OrdinalIgnoreCase);
            if (i > 0) name = name[..i];
        }
        var semi = name.IndexOf(';');
        if (semi > 0) name = name[..semi];
        return name.Trim();
    }

    /// No two songs by the same artist next to each other, where it can be helped.
    static List<BaseItem> Spaced(List<BaseItem> songs)
    {
        var remaining = songs.ToList();
        var result = new List<BaseItem>();
        while (remaining.Count > 0)
        {
            var last = result.Count > 0 ? Primary(result[^1]) : null;
            var index = remaining.FindIndex(s => Primary(s) != last);
            if (index < 0) index = 0;
            result.Add(remaining[index]);
            remaining.RemoveAt(index);
        }
        return result;
    }

    MixtapeSet Build(User user, HashSet<string> avoid)
    {
        var day = Today;
        var l = Listen(user);
        var set = new MixtapeSet { Day = day };

        bool Eligible(BaseItem s) => !l.Heard(N(s.Id), 3);

        List<BaseItem> Pick(IEnumerable<BaseItem> songs, int count, string salt, Func<BaseItem, double>? weight = null)
        {
            if (count <= 0) return new();
            return songs.Select(s =>
            {
                var u = Math.Min(Math.Max(Noise(N(s.Id), day, salt), 0.001), 0.999);
                return (s, Key: Math.Pow(u, 1 / Math.Max(weight?.Invoke(s) ?? 1, 0.05)));
            }).OrderByDescending(x => x.Key).Take(count).Select(x => x.s).ToList();
        }

        void Add(string title, string subtitle, List<BaseItem> songs)
        {
            if (songs.Count < 12) return;
            var ordered = Spaced(songs.OrderBy(s => Noise(N(s.Id), day, "order" + title)).ToList());
            var covers = ordered.Select(s => s.ParentId).Where(g => g != Guid.Empty).Select(N).Distinct().Take(4).ToList();
            set.Mixes.Add(new Mixtape
            {
                Id = "mix-" + new string(title.ToLowerInvariant().Where(char.IsLetterOrDigit).ToArray()),
                Title = title, Subtitle = subtitle, Palette = (Palettes.GetValueOrDefault(title) ?? new[] { "#333366", "#8C73D9" }).ToList(),
                TrackIds = ordered.Select(s => N(s.Id)).ToList(), CoverIds = covers,
            });
        }

        // Songs you play now, ones you loved but have not heard in a while, and ones you never played.
        List<BaseItem> Blend(IEnumerable<BaseItem> pool, int count, string salt)
        {
            var ok = pool.Where(Eligible).ToList();
            var fresh = ok.Where(s => !avoid.Contains(N(s.Id))).ToList();
            var usable = fresh.Count >= count ? fresh : ok;
            var current = usable.Where(s => l.IsKnown(N(s.Id)) && l.Heard(N(s.Id), 30));
            var forgotten = usable.Where(s => l.IsKnown(N(s.Id)) && !l.Heard(N(s.Id), 60));
            var unplayed = usable.Where(s => !l.IsKnown(N(s.Id)));
            var picks = Pick(current, count * 3 / 10, salt + "a", s => l.Weight(N(s.Id)) + 0.2);
            picks.AddRange(Pick(forgotten, count * 4 / 10, salt + "b", s => l.Weight(N(s.Id)) + 0.2));
            picks.AddRange(Pick(unplayed, count * 3 / 10, salt + "c"));
            if (picks.Count < count)
            {
                var have = picks.Select(p => p.Id).ToHashSet();
                picks.AddRange(Pick(usable.Where(s => !have.Contains(s.Id)), count - picks.Count, salt + "d"));
            }
            return picks;
        }

        var basis = l.Played.Concat(l.Favs).GroupBy(s => s.Id).Select(g => g.First()).ToList();

        // The daily mixes are made from the whole library, not only from what you played: a library of every genre should give
        // mixes of every genre, with what you play most only weighing more. (Songs without a genre tag borrow their album's.)
        var catalog = _library.GetItemList(new InternalItemsQuery(user)
        {
            IncludeItemTypes = new[] { BaseItemKind.Audio }, Recursive = true, Limit = 6000,
        }).ToList();
        var universe = basis.Concat(catalog).GroupBy(s => s.Id).Select(g => g.First()).ToList();
        var albumGenres = new Dictionary<Guid, string[]>();
        string[] GenresOf(BaseItem song)
        {
            if (song.Genres is { Length: > 0 } own) return own;
            if (song.ParentId == Guid.Empty) return Array.Empty<string>();
            if (!albumGenres.TryGetValue(song.ParentId, out var fromAlbum))
                albumGenres[song.ParentId] = fromAlbum = _library.GetItemById(song.ParentId)?.Genres ?? Array.Empty<string>();
            return fromAlbum;
        }

        // Daily Mix 1 to 3: three different kinds of music from your taste. Artists are grouped by the genres they share, so each mix
        // has its own vibe, and each mix spreads over many artists (a couple of songs each) instead of leaning on a few.
        double Cosine(Dictionary<string, double> x, Dictionary<string, double> y)
        {
            double dot = 0, nx = 0, ny = 0;
            foreach (var (k, v) in x) { nx += v * v; if (y.TryGetValue(k, out var w)) dot += v * w; }
            foreach (var v in y.Values) ny += v * v;
            return nx == 0 || ny == 0 ? 0 : dot / Math.Sqrt(nx * ny);
        }

        // A song's taste: its genre families and its specific tags ("trap", "boom bap" tell apart what "hip-hop" lumps together).
        Dictionary<string, double> Vector(BaseItem song)
        {
            var v = new Dictionary<string, double>();
            foreach (var tag in GenresOf(song))
            {
                foreach (var family in GenreNames.Canonical(tag)) v["f:" + family.ToLowerInvariant()] = 1.0;
                var raw = tag.Trim().ToLowerInvariant();
                if (raw.Length > 0) v["t:" + raw] = 0.8;
            }
            return v;
        }

        var artistSongs = new Dictionary<string, List<BaseItem>>();
        foreach (var song in universe)
        {
            var key = Primary(song);
            if (key == "") continue;
            if (!artistSongs.TryGetValue(key, out var list)) artistSongs[key] = list = new();
            list.Add(song);
        }
        // Artists you play in the same sitting belong together (how Spotify groups: by how you listen, not by tags). A sitting is
        // plays with less than 45 minutes between them; the artists in it are linked, a few at a time so one long evening does not link everything.
        var artistOfSong = new Dictionary<string, string>();
        foreach (var (key, list) in artistSongs) foreach (var song in list) artistOfSong[N(song.Id)] = key;
        var together = new Dictionary<string, Dictionary<string, double>>();
        void Link(List<string> sitting)
        {
            var artists = sitting.Distinct().Take(12).ToList();
            for (var a = 0; a < artists.Count; a++) for (var b = 0; b < artists.Count; b++)
            {
                if (a == b) continue;
                if (!together.TryGetValue(artists[a], out var row)) together[artists[a]] = row = new();
                row[artists[b]] = row.GetValueOrDefault(artists[b]) + 1.0 / artists.Count;
            }
        }
        var current = new List<string>(); DateTime? lastAt = null;
        foreach (var (id, at, seconds) in l.History)
        {
            if (seconds < 30 || !artistOfSong.TryGetValue(id, out var artist)) continue;
            if (lastAt is { } prev && at - prev > TimeSpan.FromMinutes(45)) { Link(current); current = new(); }
            current.Add(artist); lastAt = at;
        }
        Link(current);

        var profiles = artistSongs.Select(kv =>
        {
            var vec = new Dictionary<string, double>();
            double weight = 0;
            foreach (var song in kv.Value)
            {
                var w = l.Weight(N(song.Id)) + 0.1;
                weight += w;
                foreach (var (tag, x) in Vector(song)) vec[tag] = vec.GetValueOrDefault(tag) + x * w;
            }
            // Genres and company each count as one unit; the company you keep counts double when there is any.
            double Length(Dictionary<string, double> d) => Math.Sqrt(d.Values.Sum(x => x * x));
            var genreLength = Length(vec);
            if (genreLength > 0) foreach (var k in vec.Keys.ToList()) vec[k] /= genreLength;
            if (together.TryGetValue(kv.Key, out var company) && company.Count > 0)
            {
                var companyLength = Length(company);
                foreach (var (other, x) in company) vec["a:" + other] = 2.0 * x / companyLength;
                if (genreLength == 0) vec["a:" + kv.Key] = 0.001;
            }
            return (Key: kv.Key, Name: PrimaryName(kv.Value[0]), Weight: Math.Sqrt(weight), Vec: vec, Songs: kv.Value);
        }).Where(p => p.Vec.Count > 0).OrderByDescending(p => p.Weight).Take(200).ToList();

        var clusters = new List<(Dictionary<string, double> Centre, List<int> Members)>();
        // Each day the mixes start from one of your top artists (not always the heaviest), so they split differently.
        var first = profiles.Count == 0 ? 0 : (int)(Noise("start", day, "cluster") * Math.Min(profiles.Count, 8));
        if (profiles.Count >= 6)
        {
            var k = Math.Min(3, profiles.Count / 3);
            var centres = new List<Dictionary<string, double>> { profiles[first].Vec };
            // The next centres are the heavy artists least like the ones already chosen.
            while (centres.Count < k)
            {
                var best = -1; var bestScore = double.MinValue;
                for (var i = 0; i < Math.Min(profiles.Count, 40); i++)
                {
                    var score = profiles[i].Weight * (1 - centres.Max(c => Cosine(c, profiles[i].Vec)));
                    if (score > bestScore) { bestScore = score; best = i; }
                }
                centres.Add(profiles[best].Vec);
            }
            var assign = new int[profiles.Count];
            for (var round = 0; round < 12; round++)
            {
                for (var i = 0; i < profiles.Count; i++)
                {
                    var bi = 0; var bs = -1.0;
                    for (var c = 0; c < centres.Count; c++) { var sim = Cosine(centres[c], profiles[i].Vec); if (sim > bs) { bs = sim; bi = c; } }
                    assign[i] = bi;
                }
                for (var c = 0; c < centres.Count; c++)
                {
                    var sum = new Dictionary<string, double>();
                    for (var i = 0; i < profiles.Count; i++)
                        if (assign[i] == c)
                        {
                            var norm = Math.Sqrt(profiles[i].Vec.Values.Sum(x => x * x));
                            foreach (var (tag, x) in profiles[i].Vec) sum[tag] = sum.GetValueOrDefault(tag) + x / norm * profiles[i].Weight;
                        }
                    if (sum.Count > 0) centres[c] = sum;
                }
            }
            for (var c = 0; c < centres.Count; c++)
            {
                var members = Enumerable.Range(0, profiles.Count).Where(i => assign[i] == c).ToList();
                if (members.Count >= 2) clusters.Add((centres[c], members));
            }
            clusters = clusters.OrderByDescending(cl => cl.Members.Sum(i => profiles[i].Weight)).ToList();
        }

        // If the genres did not tell three kinds of music apart (everything tagged alike), still make three different mixes:
        // artists ordered by how close they are to your most played one, cut into thirds (close, in between, far).
        if (clusters.Count < 3 && profiles.Count >= 9)
        {
            var order = Enumerable.Range(0, profiles.Count).OrderByDescending(i => Cosine(profiles[first].Vec, profiles[i].Vec)).ToList();
            var size = (int)Math.Ceiling(order.Count / 3.0);
            clusters = new();
            for (var part = 0; part < 3; part++)
            {
                var members = order.Skip(part * size).Take(size).ToList();
                if (members.Count < 2) continue;
                var centre = new Dictionary<string, double>();
                foreach (var i in members)
                {
                    var norm = Math.Sqrt(profiles[i].Vec.Values.Sum(x => x * x));
                    if (norm == 0) continue;
                    foreach (var (tag, x) in profiles[i].Vec) centre[tag] = centre.GetValueOrDefault(tag) + x / norm;
                }
                clusters.Add((centre, members));
            }
        }

        // At most two songs per artist (three, then more, only if the mix would be short), so a mix is many artists.
        List<BaseItem> Spread(List<BaseItem> picks, int count)
        {
            foreach (var cap in new[] { 2, 3, 6 })
            {
                var perArtist = new Dictionary<string, int>();
                var chosen = new List<BaseItem>();
                foreach (var song in picks)
                {
                    var key = Primary(song);
                    if (perArtist.GetValueOrDefault(key) >= cap) continue;
                    perArtist[key] = perArtist.GetValueOrDefault(key) + 1;
                    chosen.Add(song);
                    if (chosen.Count == count) return chosen;
                }
                if (cap == 6) return chosen;
            }
            return picks.Take(count).ToList();
        }

        var artistCluster = new Dictionary<string, int>();
        for (var c = 0; c < clusters.Count; c++) foreach (var i in clusters[c].Members) artistCluster[profiles[i].Key] = c;

        for (var c = 0; c < Math.Min(clusters.Count, 3); c++)
        {
            var members = clusters[c].Members.Select(i => profiles[i]).ToList();
            var own = members.SelectMany(m => m.Songs).ToList();
            var tagWeight = new Dictionary<string, double>();
            foreach (var m in members) foreach (var song in m.Songs) foreach (var tag in GenresOf(song))
                tagWeight[tag] = tagWeight.GetValueOrDefault(tag) + l.Weight(N(song.Id)) + 0.1;
            var tags = tagWeight.OrderByDescending(t => t.Value).Take(8).Select(t => t.Key).ToArray();
            var library = tags.Length == 0 ? new List<BaseItem>() : _library.GetItemList(new InternalItemsQuery(user)
            {
                IncludeItemTypes = new[] { BaseItemKind.Audio }, Genres = tags, Recursive = true, Limit = 900,
                OrderBy = new[] { (ItemSortBy.Random, SortOrder.Ascending) },
            }).ToList();
            // Only songs that are closer to this mix than to the others, so the three do not blur together.
            var fitting = library.Where(song =>
            {
                var key = Primary(song);
                if (artistCluster.TryGetValue(key, out var owner)) return owner == c;
                var vec = Vector(song);
                var sims = clusters.Select(cl => Cosine(cl.Centre, vec)).ToList();
                return sims.Count > 0 && sims[c] >= 0.35 && sims[c] >= sims.Max() - 1e-9;
            });
            var pool = fitting.Concat(own).GroupBy(song => song.Id).Select(g => g.First());
            var names = members.OrderByDescending(m => m.Weight).Select(m => m.Name).Where(n => n != "").Take(3).ToList();
            var picks = Blend(pool, 90, $"daily{c}");
            // Mixed up first, or the songs you play now would always crowd out the forgotten and the new ones.
            picks = picks.OrderBy(song => Noise(N(song.Id), day, "spread" + c)).ToList();
            Add($"Daily Mix {c + 1}", names.Count == 0 ? "Your music" : string.Join(", ", names) + " and more", Spread(picks, 40));
        }

        // On Repeat: what you have been playing the most this month.
        if (l.HasHistory && l.Top30.Count > 0)
        {
            var counts = l.Top30.ToDictionary(t => t.Id, t => t.Plays);
            var items = new List<BaseItem>();
            foreach (var (id, _) in l.Top30)
                if (Guid.TryParse(id, out var g) && _library.GetItemById(g) is BaseItem item && item is Audio) items.Add(item);
            Add("On Repeat", "What you keep coming back to", Pick(items, 30, "repeat", s => counts.GetValueOrDefault(N(s.Id), 1)));
        }

        // Rewind: songs you played a lot, not heard in months.
        var rewind = l.Played.Where(s => l.Plays.GetValueOrDefault(N(s.Id)) >= 3 && !l.Heard(N(s.Id), 120)).ToList();
        var rewindFresh = rewind.Where(s => !avoid.Contains(N(s.Id))).ToList();
        Add("Rewind", "Loved once, not heard in months", Pick(rewindFresh.Count >= 20 ? rewindFresh : rewind, 35, "rewind", s => l.Weight(N(s.Id)) + 0.1));

        // Deep Cuts: songs you own and never played, by the artists you play most.
        var byArtist = new Dictionary<string, double>();
        foreach (var s in basis) { var n = (s as Audio)?.Artists?.FirstOrDefault(); if (n != null) byArtist[n] = byArtist.GetValueOrDefault(n) + l.Weight(N(s.Id)); }
        var unplayedPool = new List<BaseItem>();
        foreach (var name in byArtist.OrderByDescending(a => a.Value).Take(12).OrderBy(a => Noise(a.Key, day, "deepArtists")).Take(8).Select(a => a.Key))
        {
            try
            {
                var artist = _library.GetArtist(name);
                unplayedPool.AddRange(_library.GetItemList(new InternalItemsQuery(user)
                {
                    IncludeItemTypes = new[] { BaseItemKind.Audio }, IsPlayed = false, ArtistIds = new[] { artist.Id }, Recursive = true, Limit = 12,
                    OrderBy = new[] { (ItemSortBy.Random, SortOrder.Ascending) },
                }));
            }
            catch { }
        }
        var deepPool = unplayedPool.GroupBy(s => s.Id).Select(g => g.First()).ToList();
        var deepFresh = deepPool.Where(s => !avoid.Contains(N(s.Id))).ToList();
        Add("Deep Cuts", "Never played, by artists you love", Pick(deepFresh.Count >= 35 ? deepFresh : deepPool, 35, "deep"));

        // Time Capsule: the decade you listen to most.
        var decades = new Dictionary<int, double>();
        foreach (var s in basis) if (s.ProductionYear is >= 1900 and var y) decades[y / 10 * 10] = decades.GetValueOrDefault(y / 10 * 10) + l.Weight(N(s.Id));
        if (decades.Count > 0)
        {
            var decade = decades.OrderByDescending(d => d.Value).First().Key;
            // Albums carry the year; many songs on them have none of their own, so take every song on an album from the decade.
            var years = Enumerable.Range(decade, 10).ToArray();
            var library = _library.GetItemList(new InternalItemsQuery(user)
            {
                IncludeItemTypes = new[] { BaseItemKind.Audio }, Years = years, Recursive = true, Limit = 400,
            }).ToList();
            var albumIds = _library.GetItemList(new InternalItemsQuery(user)
            {
                IncludeItemTypes = new[] { BaseItemKind.MusicAlbum }, Years = years, Recursive = true,
            }).Select(a => a.Id).ToArray();
            foreach (var chunk in albumIds.Chunk(40))
                library.AddRange(_library.GetItemList(new InternalItemsQuery(user)
                {
                    IncludeItemTypes = new[] { BaseItemKind.Audio }, AlbumIds = chunk, Recursive = true,
                }));
            library = library.GroupBy(x => x.Id).Select(g => g.First()).ToList();
            Add("Time Capsule", $"The {decade}s", Blend(library, 40, "capsule"));
        }
        return set;
    }
}
