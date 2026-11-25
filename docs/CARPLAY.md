# CarPlay

Dial is a CarPlay **audio app**: three tabs (Home, Tune In, Library) of short lists and the system's Now Playing screen.
CarPlay draws everything itself, so Dial looks like any other music app in the car; there is nothing to size.

| Tab | What is in it |
|---|---|
| Home | Made for You (today's mixes) and Recently Played |
| Tune In | The DJ, Your Mix, Favorites Mix, and your saved radio stations |
| Library | Playlists, Artists, Albums, Favorites. Songs open with Shuffle first |

Lists are capped (`CPListTemplate.maximumItemCount`, at most 40 here) to keep eyes on the road. Now Playing has shuffle and repeat buttons.
The code is `Dial/App/CarPlay.swift`; the scene is added in `DialAppDelegate`.

## Turning it on for a real car

Apple has to approve CarPlay for the app first. It is not automatic.

1. Request the entitlement at <https://developer.apple.com/contact/carplay/> (choose **Audio**). Approval takes days to weeks.
2. In the developer account, add the **CarPlay Audio** capability to the `com.nodescraper.dial` App ID and regenerate the profile.
3. Add this to `Dial/Dial-iOS.entitlements`:
   ```xml
   <key>com.apple.developer.carplay-audio</key>
   <true/>
   ```
4. Build and install on the iPhone, plug into a CarPlay car or head unit (or use Xcode's CarPlay simulator: Simulator, **I/O, External Displays, CarPlay**).

Until step 3 the app builds and ships normally and simply does not appear in CarPlay. The simulator build already carries the
entitlement (`Dial-iOS-Simulator.entitlements`), so the CarPlay simulator works with a debug build.

## Not tested

The CarPlay screens were built to Apple's template rules and compile for iPhone, but were not run against a CarPlay screen
(no simulator window could be driven in the build environment). Check the three tabs and Now Playing once in the CarPlay simulator
before submitting.
