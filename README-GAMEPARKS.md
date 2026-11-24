# GameParks

Glenda's own cloud-gaming app for iPhone — a Starparks/XStreaming-style
front-end (poster library, one-tap play, host status, stream settings,
play stats) on top of the open-source Moonlight/GameStream streaming
engine, talking to Sunshine on her PC.

The engine (pairing, discovery, decoding, input) is the upstream
Moonlight iOS code, unchanged. The GameParks face lives in
`Limelight/GameParks/` and is installed as the app's root UI by a
two-line hook in `AppDelegate.m`. The stock Moonlight UI is never shown.

## Highlights

- Home: greeting, live host card, Continue Playing hero, "Jump back in"
  (Steam library) and "Your classics" (her own non-Steam installs) rails.
- Library: the host's full Sunshine app list — Steam games and manually
  added .exe entries (including Desktop) — searchable, with filters.
- Game page, host page, stream presets and settings, local play stats.
- Settled defaults: 1080p · 60 fps · 20 Mb/s · codec on Auto (never forced).
- Cover art for her eight games is bundled as local JPEGs — no network
  art, no WebP.
- Accent: cyan / sky blue (#3FD8F2) on the dark design palette.

## Building the unsigned IPA

GitHub Actions workflow `.github/workflows/build-ipa.yml`
(runs-on macos-15, matching the account's supported runners):

1. Check out with submodules (the engine needs moonlight-common-c + X1Kit).
2. `xcodebuild -project Moonlight.xcodeproj -scheme GameParks
   -configuration Release -sdk iphoneos CODE_SIGNING_ALLOWED=NO`.
3. Zip the `.app` into `Payload/` → `GameParks-unsigned.ipa` artifact.

The IPA is unsigned on purpose: it runs inside LiveContainer on the
phone, so no certificate, no App Store and no sideload slot is used.

Bundle ID: `com.gameparks.GameParks` · Version: 1.0

## Licence

The streaming engine is Moonlight iOS (GPLv3) — see `LICENSE.txt`.
GameParks' own front-end code is in `Limelight/GameParks/`.
Cover art belongs to the games' publishers; it is bundled for personal use.
