# The Dial plugin

A Jellyfin server plugin that makes **Discovery** and the **made-for-you mixtapes** once a day, on your server, so every device shows the same thing and opens instantly. It is optional: without it the apps hide those two parts and everything else works.

Targets **Jellyfin 12.x** (.NET 10, ABI `12.0.0.0`).

## What it does

| Part | What it makes |
|---|---|
| **Discovery feed** | New releases from the artists you play most (MusicBrainz), minus albums you already own; *Fans of …* rows for your top artists (ListenBrainz, with photos from Wikidata); upcoming concerts (Ticketmaster, optional). Per user. |
| **Mixtapes** | Daily Mix 1 to 3 (three different kinds of music from your whole library: artists are grouped by who you play in the same sitting and by genre, each mix spreads over many artists with at most two songs each, and songs you keep skipping count for less), On Repeat (this month's most played), Rewind (loved once, not heard in months), Deep Cuts (unplayed songs by artists you love), Time Capsule (your favourite decade, every song on its albums). Per user, rested day to day. |

Both are built by scheduled tasks in the small hours (**Refresh Dial Discovery** at 04:00, **Refresh Dial Mixtapes** at 04:30), and on demand the first time an app asks. Results are cached on disk in the plugin's data folder.

## Install

The easy way: add Dial's plugin repository to your server, then install it from the catalog. No build needed.

1. In Jellyfin, open **Dashboard → Plugins → Repositories → Add repository**.
2. Name it **Dial** and paste this address:

   ```
   https://raw.githubusercontent.com/nodescraper/dial/main/manifest.json
   ```

3. Open **Dashboard → Plugins → Catalog**, find **Dial**, and click **Install**.
4. Restart Jellyfin. **Dial** should show as *Active* under **Dashboard → Plugins**.

**Doing it by hand instead** (for example, if you want to build the plugin yourself) needs the **.NET 10 SDK**:

```bash
git clone https://github.com/nodescraper/dial.git
cd dial
dotnet build -c Release Plugin
```

Copy the result into your Jellyfin config folder, in its own directory:

```bash
# Docker example: <config> is the folder you mount at /config
mkdir -p <config>/plugins/Dial_0.1.0.0
cp Plugin/bin/Release/net10.0/Dial.Plugin.dll <config>/plugins/Dial_0.1.0.0/
```

Restart Jellyfin. (The message "An error occurred while getting the plugin details from the repository" is normal for a plugin installed by hand.)

## Settings

Open **Dashboard → Plugins → Dial**.

- **What Dial needs and uses**: a live status table. Green is working, orange is off or missing, with a note on what you lose. It covers the Jellyfin plugins it builds on (Playback Reporting, AudioMuse AI, MusicBrainz, ListenBrainz Similarity), the online services it asks, and whether the feed and mixtapes were made.
- **Show upcoming concerts**, **Ticketmaster API key** and **Country code**: get a free key at [developer.ticketmaster.com](https://developer.ticketmaster.com/). Saving starts a fresh build.

The same status appears in the apps under **Settings → Server Add-ons**.

## What helps it

| Plugin | Why |
|---|---|
| **MusicBrainz** provider enabled on your Music library | Gives artists the `MusicBrainzArtist` ID. Without it, Discovery has nothing to follow. |
| **Playback Reporting** | The *On Repeat* mixtape and exact recent-play history. Without it, On Repeat is left out and the other mixtapes use Jellyfin's own play counts. |
| **AudioMuse AI** | Mood mixtapes and the vibes behind Marlo (these are made in the app today, not the plugin). |

## API

All endpoints need a signed-in user (same token as the rest of Jellyfin).

| Method and path | Returns |
|---|---|
| `GET /Dial/Ping` | `{ name, version, api }`: how the apps detect the plugin. |
| `GET /Dial/Discovery` | The finished feed (`fresh`, `fans`, `concerts`, `upcoming` releases, `artists`). `202 {"ready":false}` while the first one is being made. |
| `POST /Dial/Discovery/Refresh` | Starts a fresh build now. |
| `GET /Dial/Discovery/Status` | Whether the feed is being made. |
| `GET /Dial/Mixtapes` | Today's mixtapes: ids, titles, palettes, track ids. |
| `POST /Dial/Mixtapes/Refresh` | Rebuilds today's mixtapes now (the *Regenerate mixtapes* button). |
| `GET /Dial/Mixtapes/Status` | Whether the mixtapes are being made. |
| `GET /Dial/Status` | The grouped status used by the settings pages. |
| `GET /Dial/Settings` · `POST /Dial/Settings` | Concert settings (the write needs an administrator). |

The feed's shape matches the apps' own types, so a feed decodes as it is.

## Privacy

The plugin makes outgoing requests from your server:

| Service | What is sent | Why |
|---|---|---|
| MusicBrainz | An artist's MusicBrainz ID | Their discography |
| ListenBrainz | An artist's MusicBrainz ID | Similar artists |
| Wikidata | MusicBrainz IDs | Artist photos |
| Ticketmaster | Artist **names**, your **country code** and your key | Concerts. Only when you add a key. |

Your play history and library never leave the server. The apps additionally load covers from the Cover Art Archive and photos from Wikimedia Commons, and look up artists you do not own on MusicBrainz when you open their page.

## Build and develop

```bash
dotnet build -c Release Plugin
```

Code lives in `Plugin/`: `Api/` (endpoints), `Services/` (discovery, mixtapes, tasks, genre families), `Web/config.html` (the settings page).

## Roadmap

- Mood mixtapes made on the server too (today the app makes them with AudioMuse).
- Marlo's vibe drift on the server.
