# Dial for Android

Dial's Android app: native Kotlin with Jetpack Compose, Material 3 Expressive, and Media3 for playback.
It talks to the same Jellyfin server as Dial on iPhone and Mac.

## What's in it
- Sign in with your password, or with **Quick Connect**: Dial shows a code, you approve it in Jellyfin on your phone.
  
- **Home:** a Material carousel of recently added albums, recently played songs, favorite albums, Shuffle All.
- **Radio:** Your Mix, Favorites Mix, artist radio, and AudioMuse mood stations when the plugin offers sound search.
- **Search:** filter chips (All, Songs, Albums, Artists, Playlists) while searching; before you type, your genres and
  decades as tiles made of your own album covers, opening genre and decade pages with Play and Shuffle.
- **Artist pages:** top songs, the **full discography** from MusicBrainz (albums you have open; the rest are faded and
  open a tracklist page where songs you have elsewhere still play), **Featured On** (songs where they're a guest),
  and similar artists from your library (ListenBrainz).
- **Featured artists:** "Post Malone feat. Justin Bieber" credits both. Artists who only appear as features get their own
  page (photo from Wikimedia Commons) and a section in Library, Artists. Only marked features count, and "&" only splits between
  artists known on their own.
- **Import Playlists** (Library): Spotify's data download (playlists, liked songs, your top 500 from listening history),
  Exportify CSV, or "Artist - Title" lists, matched to your library; play or save as a Jellyfin playlist.
- **Lyrics** in the player: from your server, or from LRCLIB when your server has none. Synced lyrics follow along;
  tap a line to jump there.
- **Hidden songs:** "Don't Play This Song" in any song's menu; radio and mixes skip them.
- **Player:** colors from the album cover, the wavy progress bar, the morphing play button, springy motion, toggle
  buttons for favorite, shuffle, repeat, radio, lyrics and the queue; every credited artist is tappable.
- **Background playback**, notification and lock screen controls, gapless playback, **Android Auto**.

- **One session across your devices, like Spotify Connect** (the same as Dial on iPhone and Mac): the devices button
  (Home and the player) lists your other Dial and Jellyfin apps; the music moves there from the same spot and this
  device becomes the remote, with that device's volume. Your Dials notice each other: open Dial while another plays
  and it shows "Playing on …"; start music elsewhere and the newest playback wins. Live radio moves between Dials too.
  Favorites sync live between devices.
- **Marlo:** not on Android yet (planned as a Jellyfin plugin). The Radio tab says so and offers to start Marlo on your
  iPhone or Mac; while Marlo plays there, this device shows its block and on-air words and can talk to it.
- **Live radio** from Radio Browser: categories and search.
- **Search before you type:** a discovery page from open music data: new releases from your artists, who fans of your
  artists also play, this week's popular artists and albums (ListenBrainz), fresh releases, and genres to explore.
  While typing, your library first, then "Beyond Your Library" from MusicBrainz.
- **Downloads and offline:** download songs or whole albums (Android's download service keeps going in the background);
  when your server can't be reached, Dial says so and plays your downloads.
- **Crossfade** (up to 12 seconds; songs that flow into each other on the same album stay gapless), **volume leveling**,
  and the phone's **equalizer** with its presets, in Settings.

## Not yet
Marlo itself (planned as a Jellyfin plugin).

## Building
1. Install Android Studio (a current version).
2. Open this folder (`Android`) in Android Studio. It downloads Gradle and the libraries the first time.
3. If Android Studio suggests updating library versions, accept: Material 3 needs to be 1.4 or later for the
   Expressive components.
4. Connect your phone with USB debugging turned on (Settings, About phone, tap Build number 7 times,
   then Developer options, USB debugging), and press Run.

This code hasn't been compiled yet, so expect a few errors on the first build; send them over and I'll fix them.

Dial for TV is a separate app in `AndroidTV/DialTV`.
