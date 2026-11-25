using System.Text.Json;
using Dial.Plugin.Services;
using Microsoft.AspNetCore.Authorization;
using Microsoft.AspNetCore.Mvc;

namespace Dial.Plugin.Api;

[ApiController]
[Route("Dial")]
[Authorize]
public class DialController : ControllerBase
{
    readonly DiscoveryService _discovery;
    readonly MixtapeService _mixtapes;
    readonly WishlistService _wishlist;
    readonly MediaBrowser.Common.Plugins.IPluginManager _plugins;
    public DialController(DiscoveryService discovery, MixtapeService mixtapes, WishlistService wishlist,
                          MediaBrowser.Common.Plugins.IPluginManager plugins)
    { _discovery = discovery; _mixtapes = mixtapes; _wishlist = wishlist; _plugins = plugins; }

    Guid? Me => Guid.TryParse(User.FindFirst("Jellyfin-UserId")?.Value, out var id) ? id : null;

    /// The apps call this to find out whether the plugin is installed.
    [HttpGet("Ping")]
    public ActionResult<object> Ping() => new { name = "Dial", version = "0.1.0", api = 1 };

    /// The finished Discovery feed for the signed-in user. Not made yet: 202, and it starts being made.
    [HttpGet("Discovery")]
    public IActionResult Discovery()
    {
        if (Me is not { } me) return Unauthorized();
        var json = _discovery.ReadFeed(me);
        if (json == null)
        {
            _ = Task.Run(() => _discovery.RefreshAsync(me, CancellationToken.None));
            return StatusCode(202, new { ready = false });
        }
        return Content(json, "application/json");
    }

    /// Starts making a fresh feed now (it is also made every night).
    [HttpPost("Discovery/Refresh")]
    public IActionResult Refresh()
    {
        if (Me is not { } me) return Unauthorized();
        _ = Task.Run(() => _discovery.RefreshAsync(me, CancellationToken.None));
        return Accepted(new { running = true });
    }

    [HttpGet("Discovery/Status")]
    public ActionResult<object> DiscoveryStatus() => new { running = _discovery.IsRunning };

    /// Today's mixtapes for the signed-in user (made-for-you mixes). Made on first ask, renewed every night.
    [HttpGet("Mixtapes")]
    public IActionResult Mixtapes()
    {
        if (Me is not { } me) return Unauthorized();
        var (json, current) = _mixtapes.Read(me);
        if (!current) _ = Task.Run(() => _mixtapes.RefreshAsync(me, CancellationToken.None));
        if (json == null) return StatusCode(202, new { ready = false });
        return Content(json, "application/json");
    }

    /// Builds new mixtapes for everyone now (they are also made every night). Songs of the current ones are left out, so they come out fresh.
    [HttpPost("Mixtapes/Refresh")]
    [Authorize(Policy = "RequiresElevation")]
    public IActionResult RefreshMixtapes()
    {
        if (_mixtapes.IsRunning) return Accepted(new { running = true });
        _ = Task.Run(() => _mixtapes.RefreshAllAsync(null, CancellationToken.None));
        return Accepted(new { running = true });
    }

    [HttpGet("Mixtapes/Status")]
    public ActionResult<object> MixtapeStatus() => new { running = _mixtapes.IsRunning };

    /// The signed-in user's wishlist: albums and songs they want but don't have, newest first.
    [HttpGet("Wishlist")]
    public IActionResult Wishlist()
    {
        if (Me is not { } me) return Unauthorized();
        return Content(_wishlist.Read(me), "application/json");
    }

    /// Adds an item to the wishlist (an object with an "id"); answers the whole list.
    [HttpPost("Wishlist")]
    public IActionResult AddToWishlist([FromBody] JsonElement item)
    {
        if (Me is not { } me) return Unauthorized();
        if (!_wishlist.Add(me, item, out var json)) return BadRequest(new { error = "An item needs an id and must be small." });
        return Content(json, "application/json");
    }

    /// Takes an item off the wishlist; answers the whole list.
    [HttpDelete("Wishlist/{id}")]
    public IActionResult RemoveFromWishlist(string id)
    {
        if (Me is not { } me) return Unauthorized();
        return Content(_wishlist.Remove(me, id), "application/json");
    }

    /// Everything Dial needs and uses, in groups, with what each gives the app (shown on the plugin's settings page).
    [HttpGet("Status")]
    public ActionResult<object> Status()
    {
        var installed = _plugins.Plugins.Where(p => p.Manifest.Status == MediaBrowser.Model.Plugins.PluginStatus.Active)
            .Select(p => p.Manifest.Name ?? "").ToList();
        bool Has(string part) => installed.Any(n => n.Contains(part, StringComparison.OrdinalIgnoreCase));
        var c = DialPlugin.Instance!.Configuration;
        var concerts = c.ConcertsEnabled && c.TicketmasterKey.Length > 0;
        object Row(string name, bool active, string provides, string? note = null) => new { name, active, provides, note };
        var feedAt = Me is { } me ? _discovery.FeedTime(me) : null;
        var (_, mixesCurrent) = Me is { } m2 ? _mixtapes.Read(m2) : (null, false);
        return new
        {
            groups = new object[]
            {
                new { title = "Dial", rows = new[]
                {
                    Row("Discovery feed", feedAt != null, "The Discovery tab: new releases from your artists, fans also play, On Tour.",
                        feedAt == null ? "Not made yet: it is made the first time Discovery is opened, then every night at 04:00." : "Last made " + feedAt.Value.ToLocalTime().ToString("yyyy-MM-dd HH:mm") + "."),
                    Row("Mixtapes", mixesCurrent, "Daily Mix 1-3, On Repeat, Rewind, Deep Cuts and Time Capsule, the same on every device.",
                        mixesCurrent ? "Made for today." : "Made the first time the app asks each day, then every night at 04:30."),
                } },
                new { title = "Jellyfin plugins it builds on", rows = new[]
                {
                    Row("Playback Reporting", Has("Playback Reporting"), "The On Repeat mixtape (your most played songs this month) and exact play history for every mixtape.",
                        Has("Playback Reporting") ? null : "Without it, On Repeat is left out and the other mixtapes use Jellyfin's own play counts."),
                    Row("AudioMuse AI", Has("AudioMuse"), "Mood mixtapes and sound search for the DJ (Marlo), made from analysed audio.",
                        Has("AudioMuse") ? null : "Without it there are no mood mixtapes and the DJ cannot search by sound."),
                    Row("MusicBrainz", Has("MusicBrainz"), "Gives your artists their MusicBrainz ID, which links your library to new releases and similar artists.",
                        Has("MusicBrainz") ? null : "Without it, Discovery has no artists to look up. Turn it on in Dashboard, Libraries, Music."),
                    Row("ListenBrainz Similarity", Has("ListenBrainz"), "Similar artists inside Jellyfin (Dial asks ListenBrainz directly for Discovery).", "Optional."),
                } },
                new { title = "Online services it asks", rows = new[]
                {
                    Row("MusicBrainz database", true, "Every artist's discography, to find releases you do not have yet.", "Free. One request a second, results kept for 3 days."),
                    Row("ListenBrainz", true, "Fans of your top artists also play: similar artists.", "Free. Results kept for a week."),
                    Row("Wikidata and Wikimedia Commons", true, "Artist photos in the fans-also-play row.", "Free. Kept for a month."),
                    Row("Cover Art Archive", true, "Covers for new releases (the apps load them directly).", "Free."),
                    Row("Ticketmaster Discovery", concerts, "The On Tour row: upcoming concerts of artists you own.",
                        concerts ? "Country: " + (c.CountryCode.Length > 0 ? c.CountryCode : "any") + "." : "Off: add a free API key and a country below."),
                } },
            },
        };
    }

    [HttpGet("Settings")]
    public ActionResult<object> GetSettings()
    {
        var c = DialPlugin.Instance!.Configuration;
        return new { concertsEnabled = c.ConcertsEnabled, countryCode = c.CountryCode, hasTicketmasterKey = c.TicketmasterKey.Length > 0 };
    }

    public class SettingsBody
    {
        public string? TicketmasterKey { get; set; }
        public string? CountryCode { get; set; }
        public bool? ConcertsEnabled { get; set; }
    }

    [HttpPost("Settings")]
    [Authorize(Policy = "RequiresElevation")]
    public IActionResult SetSettings([FromBody] SettingsBody body)
    {
        var plugin = DialPlugin.Instance!;
        var c = plugin.Configuration;
        if (body.TicketmasterKey != null) c.TicketmasterKey = body.TicketmasterKey.Trim();
        if (body.CountryCode != null) c.CountryCode = body.CountryCode.Trim().ToUpperInvariant();
        if (body.ConcertsEnabled is { } on) c.ConcertsEnabled = on;
        plugin.UpdateConfiguration(c);
        return NoContent();
    }
}
