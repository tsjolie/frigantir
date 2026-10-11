# Frigantir

An unofficial native iOS client for [Frigate NVR](https://frigate.video) that replaces the
PWA. It has low-latency live view decoded in hardware, background audio that
works as a baby monitor with the phone locked, Picture in Picture, and push
notifications through a small self-hosted relay ([notifier/](notifier/README.md)).

* **Requirements:** Xcode 26 or newer, iOS 18+ device, Frigate 0.14+ (built against 0.18)
* **Plan and architecture:** [docs/PROJECT_PLAN.md](docs/PROJECT_PLAN.md)

## Quick start

```sh
make bootstrap                 # XcodeGen, SwiftLint, fastlane
cp .env.example .env           # set DEVELOPMENT_TEAM (your Apple Team ID)
make open                      # generates FrigateApp.xcodeproj and opens Xcode
```

Run on a simulator or device with ⌘R, then enter your Frigate URL on first
launch (e.g. `https://frigate.example.com`). `make test` runs the unit tests and
`make lint` runs SwiftLint.

## Layout

```
project.yml            XcodeGen spec (source of truth for the Xcode project)
FrigateApp/            app sources: App, Core (API, storage), Playback, Features
FrigateAppTests/       unit tests + synthetic fMP4 fixture
notifier/              push notification relay (Docker); see notifier/README.md
fastlane/              test / certificates / beta lanes
docs/                  project plan, App Store submission guide, privacy policy
```

## License

[MIT](LICENSE). Not affiliated with the Frigate project.
