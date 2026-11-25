# Building

## iPhone, iPad and Mac

Requirements: a Mac with **Xcode 26.1 or newer**, [XcodeGen](https://github.com/yonaskolb/XcodeGen), an iPhone or iPad on **iOS 17+** (iOS 26.1 gets the native Liquid Glass mini player).

```bash
brew install xcodegen
xcodegen            # makes Dial.xcodeproj from project.yml
open Dial.xcodeproj
```

1. Select the **Dial** target, then **Signing & Capabilities**, and choose your **Team**.
2. Change the **bundle identifier** (in `project.yml`, `PRODUCT_BUNDLE_IDENTIFIER`) to something of yours, and the `DEVELOPMENT_TEAM` to your own team ID, then run `xcodegen` again.
3. Pick your device and press **Run**. First time on a device: enable **Developer Mode** and trust your certificate.
4. Allow **Local Network** access when asked.

With a free Apple ID the app expires after 7 days; run again to reinstall.

### Mac

Choose **My Mac (Mac Catalyst)** as the destination. To install a signed copy, build in Release or Debug with automatic signing and copy `Dial.app` into `/Applications`.

## Android

Folder [`Android/`](../Android). Requirements: **JDK 17**, Android SDK.

```bash
cd Android
gradle :app:assembleDebug        # Gradle 9; there is no wrapper script checked in
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

## Android TV

Folder [`AndroidTV/`](../AndroidTV). It compiles the phone app's data layer (`AndroidTV/DialAndroid`) plus its own screens.

```bash
cd AndroidTV/DialTV
gradle :app:assembleDebug
adb connect <tv-ip>:5555
adb install -r app/build/outputs/apk/debug/app-debug.apk
```

On the TV, enable **Developer options** and **ADB debugging** (or sideload with the *Downloader* app).

## The plugin

```bash
dotnet build -c Release Plugin
```

Needs the **.NET 10 SDK**. Install steps are in [PLUGIN.md](PLUGIN.md).
