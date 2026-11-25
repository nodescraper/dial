# Digitising your own music

Dial is built for people who own their music. This guide covers getting your collection into a form that Jellyfin, and therefore Dial, can use well: ripped or captured at good quality, tagged correctly, and organised so nothing gets lost.

> Dial is for music you own or have the right to keep: your CDs, records, tapes and downloads you bought. It does not help you find music you do not own.

## What "good" looks like

Dial's best features (Discovery, mixtapes, Marlo's vibes) rely on **good tags**. Three things matter most:

1. **Correct artist, album, title, track and year tags.**
2. **MusicBrainz IDs** in the files (artist, album, track). They link your library to new releases, similar artists and concerts.
3. **Embedded cover art** (or a `cover.jpg` in each album folder).

The rest is quality and tidiness.

## Pick a format

| Format | Use it when | Notes |
|---|---|---|
| **FLAC** | You want the archive | Lossless, widely supported, free, tags and art embedded. Best default for CDs. |
| **ALAC** | You live in the Apple world | Lossless, plays everywhere Apple does, a bit bigger tag-tool support gap. |
| **Opus / AAC / MP3 320** | Phone storage matters | Use for *copies* (Dial can transcode on the fly, or download smaller versions), not for your archive. |

Archive in lossless once. Let Jellyfin transcode for the phone when needed.

## Ripping CDs

Use a ripper that **verifies** the result against a database (AccurateRip), so you know the rip is bit-perfect.

| Platform | Tool | Notes |
|---|---|---|
| macOS | **XLD** | Free, supports AccurateRip, cue sheets, FLAC/ALAC. |
| Windows | **Exact Audio Copy** | The classic secure ripper. |
| Linux | **whipper** or **abcde** | whipper is the AccurateRip-aware choice. |

Tips:

- Rip to **FLAC** (or ALAC). Turn on **secure** or **paranoia** mode and **AccurateRip**.
- Let the ripper fetch tags from **MusicBrainz** (or fix them afterwards in Picard, below).
- Save the **log** and **cue** file next to the album. They are proof, and a lifesaver if you re-rip.
- A decent external drive matters more than software. Read speed is not the point; error correction is.
- Clean the disc, not the drive's settings, if a track fails. Re-rip the single track.

## Capturing vinyl

1. **Gear:** a turntable, a phono preamp (built in, or separate), and an audio interface or USB turntable. Clean the record first.
2. **Record** at 24-bit / 96 kHz (or 44.1/48 kHz if space matters) with **Audacity** (free, all platforms) or similar. Record a whole side in one go and keep that raw file.
3. **Split** into tracks at the gaps.
4. **Clean lightly.** A gentle click and pop removal is fine; heavy noise reduction ruins the music. Keep the untouched raw capture.
5. **Export** to FLAC, then tag (below).

Do *not* normalise every track to the same loudness by editing the audio. Use **ReplayGain** tags instead (see below) so the music itself stays as pressed.

## Cassettes and minidisc

Same idea as vinyl: capture with a line-in at 44.1/48 kHz, split, export to FLAC, tag. A decent deck with a clean head matters most.

## Buying DRM-free downloads

Stores that sell music you can keep, without locks:

- **Bandcamp**: artists get most of the money; offers FLAC and more.
- **Qobuz**: lossless purchases (the streaming side is separate).
- **7digital**, **Beatport** (electronic): purchases in MP3/FLAC.
- **HDtracks** and similar for hi-res.

Download the **lossless** version when offered. Bought files often arrive well tagged, but still run them through Picard so the MusicBrainz IDs are added.

## Tagging with MusicBrainz Picard

[MusicBrainz Picard](https://picard.musicbrainz.org) is the tool that turns "mostly tagged" into "properly tagged".

1. Add your album folders to Picard.
2. **Cluster**, then **Lookup** (or drop the files on the matching release if you know it).
3. Check the match. Pick the right release (country, year, edition).
4. **Save.** Picard writes the tags, the **MusicBrainz IDs** and the cover art into your files.

Why this matters for Dial:

- Jellyfin's MusicBrainz provider reads the IDs, which gives each artist a `MusicBrainzArtist` ID.
- The Dial plugin uses that ID to look up new releases, similar artists and photos.
- Without IDs, Discovery has nothing to follow.

Useful Picard settings: write **tags to the files**, embed **cover art**, and use a file naming script that produces the layout below.

## Folder layout

Jellyfin is happiest with one folder per album under one folder per artist:

```
Music/
  Artist Name/
    Album Title (2016)/
      01 First Song.flac
      02 Second Song.flac
      cover.jpg
      Album Title.cue        (optional)
      rip.log                (optional)
    Another Album (2019)/
      ...
  Various Artists/
    Compilation Title (2020)/
      ...
```

Multi-disc albums: either `Disc 1/`, `Disc 2/` subfolders, or tag the disc number and keep one folder. Compilations: tag **Album Artist** as "Various Artists" so the album stays together.

## Loudness: ReplayGain

Songs from different eras play at wildly different volumes. Instead of changing the audio, write **ReplayGain** tags (Picard plugin, `rsgain`, or `loudgain`) and turn on **Volume Leveling** in Dial's settings. The music stays untouched; the player evens it out.

## Lyrics

- Put a `.lrc` file (synced) or `.txt` next to the song, same name, or embed the lyrics in the tags.
- Or install the **LRCLIB Lyrics** plugin in Jellyfin to fetch synced lyrics automatically.

## Moving playlists in

Dial can import `.m3u` playlists that match songs in your library (Library, then Import Playlists). If you used another service, tools exist to export your playlists as CSV or M3U; match them against your own files.

## Back it up

Your library is irreplaceable. Follow **3-2-1**:

- **3** copies of everything,
- on **2** different kinds of media (say, a NAS and an external disk),
- with **1** copy somewhere else (another house, or an encrypted cloud copy).

Also keep the **raw vinyl captures** and the **rip logs**. Re-ripping a scratched disc ten years later is much easier with them.

## Tell Jellyfin

1. Add the folder as a **Music** library.
2. In the library settings, enable the **MusicBrainz** (and optionally **TheAudioDB**) metadata providers, and **real-time monitoring**.
3. Scan, then check a few artists for artwork and a MusicBrainz ID.

Next: [Server setup](SERVER-SETUP.md).
