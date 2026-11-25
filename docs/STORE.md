# Shipping Dial to the stores

Everything the stores need except the things only you can provide (accounts, keys, a contact address). Checklist first, then the texts to paste.

## One-time things only you can do

| What | Where |
|---|---|
| Apple Developer Program (paid) | Needed for TestFlight and the App Store. Team ID is already `SX4A7T7RQ7` in `project.yml` |
| Google Play Developer account (one-off fee) | play.google.com/console |
| A contact email for the privacy page | `support@dialplayer.site` is already in `Website/privacy.html`. Make it work (Namecheap, Domain, Email Forwarding, forward it to your inbox) |
| A public URL for the privacy policy | Host `Website/` on the domain dialplayer.site (Cloudflare Pages or Netlify, free). The privacy URL is `https://dialplayer.site/privacy.html`, the support URL `https://dialplayer.site` |
| CarPlay entitlement (optional, can come later) | See `docs/CARPLAY.md` |
| An Android upload key | See below |

All bundle IDs use your developer name: **`com.nodescraper.dial`** (iPhone, iPad, Mac and Android phone), `com.nodescraper.dial.Widget` (the widget),
**`com.nodescraper.dial.tv`** (Android TV).

## Apple (iPhone, iPad, Mac)

Version **1.0 (1)**, set by `MARKETING_VERSION` and `CURRENT_PROJECT_VERSION` in `project.yml`. Bump the build number for every upload.

```bash
xcodegen generate
open Dial.xcodeproj
```

1. Select the **Dial** scheme. For iPhone and iPad choose **Any iOS Device**, then **Product, Archive**, then **Distribute App, App Store Connect**.
2. For the Mac, choose **My Mac (Mac Catalyst)** and archive the same way. Both go into one App Store Connect app record (a universal purchase).
3. Create the app in App Store Connect with the bundle ID `com.nodescraper.dial`, paste the texts below, upload screenshots, set the privacy policy URL.
4. Send to TestFlight first.

Already done in the project: app icon, the widget extension, `ITSAppUsesNonExemptEncryption = NO` (no export paperwork), a privacy manifest
(`Dial/PrivacyInfo.xcprivacy`: no tracking, no collected data, UserDefaults declared), the Mac sandbox entitlements, the local-network description.

### Review notes (paste into App Store Connect, "Notes")

> Dial is a client for a user's own Jellyfin media server; it has no music of its own. To test it you need a Jellyfin server. A demo server and
> login are provided below. The app allows plain HTTP (App Transport Security exception) because Jellyfin servers are usually on a home network
> without a certificate; users also use HTTPS. The CarPlay scene is present but inactive until the CarPlay audio entitlement is granted.
>
> Demo server: <ADD A SERVER URL> / user: <ADD> / password: <ADD>

**You must provide a demo server and login**: reviewers cannot use the app without one. Make a throwaway Jellyfin user with a small music library.

### App Privacy answers

Data collected: **None**. Tracking: **No**. (The app only talks to your own server and the public services on the privacy page.)

## Android phone and Android TV

Version **0.15 (15)** phone, **0.19 (19)** TV. Raise `versionCode` for every upload (`app/build.gradle.kts`).

### Make an upload key (once)

```bash
keytool -genkeypair -v -keystore dial-upload.jks -alias dial-upload -keyalg RSA -keysize 2048 -validity 10000
cp keystore.properties.example keystore.properties   # then fill it in
```

Keep `dial-upload.jks` and its passwords somewhere safe (not in git; `keystore.properties` and `*.jks` are ignored). Use **Play App Signing** when
Google asks, so a lost upload key can be reset.

### Build the bundle

```bash
./gradlew :app:bundleRelease        # phone: Android/, TV: AndroidTV/DialTV
```

Output: `app/build/outputs/bundle/release/app-release.aab`. Upload it in the Play Console (Internal testing first). Without
`keystore.properties` the bundle is signed with the debug key and Play will reject it, so make the key first.

Needed in the Play Console: the privacy policy URL, the Data safety form (**no data collected or shared**), the content rating questionnaire
(a music player, no user content), the target audience (not for children), and for TV the 320x180 banner (already in the app) plus TV screenshots.
Android Auto needs no separate form for a media app; it shows up once the app is installed from Play.

The app asks for **no dangerous permissions** (only internet, network state, wake lock, foreground service for playback, and notifications).

## Store texts

**Name:** Dial Music Player (the App Store name; "Dial" was taken. The icon on the home screen still says Dial. App Store Connect app ID 6831943362)

**Subtitle / short description (30 / 80 characters):**
- `Your Jellyfin library, alive` (Apple subtitle)
- `A music player for your Jellyfin server with daily mixes, a DJ and discovery.` (Google short description)

**Description:**

> Dial is a music player for people who know their music. It plays your own library from your own Jellyfin server and makes it feel alive.
>
> • Daily mixes made from how you listen: Daily Mix, On Repeat, Rewind, Deep Cuts and a Time Capsule, plus mood mixes if you run AudioMuse-AI.
> • A DJ that holds a vibe for a few songs, then drifts to a neighbour, with a line at the turn. Optional.
> • Discovery from the artists you already own: new releases, who their fans listen to, and concerts (with your own Ticketmaster key).
> • Playback that follows you: start on your phone, carry on from your Mac or TV. Every device shows what the others play.
> • Synced lyrics, offline downloads, an equalizer, sleep timer, AirPlay and a Home Screen widget.
> • Live internet radio, including the Lofi Girl streams.
> • On an album, the songs you are missing are shown faded out.
>
> Dial needs a Jellyfin server of your own. It does not contain, sell or stream music. The optional Dial server plugin builds Discovery and the daily mixes once a day so every device shows the same.
>
> No accounts, no ads, no tracking. Dial is independent software and is not affiliated with Jellyfin.

**Keywords (Apple, 100 characters):** `jellyfin,music,player,self-hosted,flac,lossless,radio,lyrics,mixes,dj,discovery,carplay,widget`

**Category:** Music. **Age rating:** 4+ (Apple) / Everyone (Google). **Price:** your choice.

**What to test (TestFlight):** Sign in to your Jellyfin server, play something, open Discovery and Tune In, start the DJ, then start a song on a
second device and check the first one follows it.

## Screenshots

Sizes the stores want: iPhone 6.9" (1320x2868) and 6.5", iPad 13", Mac 1280x800 or larger; Android phone 1080x1920 or taller; TV 1920x1080.
Existing shots to start from are in `Website/assets/img/` and `docs/screenshots/`. Take final ones with a library you are happy to show (covers belong to their owners).

## Before you submit

- [ ] Demo server and login for review (Apple)
- [ ] Contact email in `Website/privacy.html`, site hosted, privacy URL added to both stores
- [ ] Upload key created and `keystore.properties` filled in (Android)
- [x] Licence: PolyForm Noncommercial 1.0.0 (source available, others may not sell it). Decided; the repo carries it
- [ ] Decide the price and whether to say so in the listing
- [ ] Walk through the CarPlay screens in the CarPlay simulator once (`docs/CARPLAY.md`) if you ship it in 1.0
