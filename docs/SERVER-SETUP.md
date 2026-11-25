# Setting up the server

Dial talks to a **Jellyfin** server. This guide gets one running and adds the optional helpers that unlock Dial's best features.

## 1. Jellyfin

Dial targets **Jellyfin 12**. The easiest way to run it is Docker.

```yaml
# docker-compose.yml
services:
  jellyfin:
    image: jellyfin/jellyfin:latest
    container_name: jellyfin
    restart: unless-stopped
    ports:
      - "8096:8096"
    volumes:
      - ./jellyfin/config:/config
      - ./jellyfin/cache:/cache
      - /path/to/your/music:/music:ro
```

```bash
docker compose up -d
```

Open `http://<server>:8096`, create your account, and add your music folder as a **Music** library.

Turn on **Quick Connect** (Dashboard → General) if you want to sign in to Dial without typing a password.

## 2. Helpers (all optional)

Install plugins from **Dashboard → Plugins → Catalog**, then restart Jellyfin.

| Plugin | What it gives Dial | Notes |
|---|---|---|
| **MusicBrainz** (built in) | MusicBrainz IDs per artist: the foundation of Discovery | Enable the provider in your Music library settings |
| **Playback Reporting** | The *On Repeat* mixtape and exact play history | Dial reads its database; nothing to configure |
| **AudioMuse AI** | Sound analysis: mood mixtapes, sound search, and the vibes Marlo drifts between | Runs as separate containers, see below |
| **LRCLIB Lyrics** | Synced lyrics when your files have none | |
| **ListenBrainz** | Optional similarity inside Jellyfin | Dial's own plugin asks ListenBrainz directly too |

### AudioMuse AI

AudioMuse analyses every song once (mood, energy, instruments) and clusters your library into groups of songs that sound alike. Dial uses those clusters as **vibes**.

1. Follow the install guide in the [AudioMuse-AI repository](https://github.com/NeptuneHub/AudioMuse-AI) (a few containers plus a Jellyfin plugin).
2. Run its **analysis** over your library, then its **clustering**. Clustering creates playlists whose names end in `_automatic`. Dial hides those from your playlists and uses them as vibes.
3. In Dial's **Settings → Server Add-ons** you will see it turn green.

The first analysis of a big library takes hours. Let it run.

## 3. The Dial plugin

Discovery and the made-for-you mixtapes come from the Dial plugin. See [PLUGIN.md](PLUGIN.md).

## 4. Reaching your server away from home

- Put Jellyfin behind a **reverse proxy with HTTPS** (Caddy, Nginx, Traefik), or
- use a private network such as **Tailscale** or WireGuard, which is the simplest safe option.

Do not expose Jellyfin to the internet without HTTPS.

## 5. Check it works

1. Open Dial, enter the server address, sign in.
2. **Settings → Server Add-ons** lists what is installed (green) and what is missing (orange), with what each one gives you.
3. Play something.
