# Tally

A lightweight macOS menu-bar app that monitors your network — live throughput, connection quality, and per-process bandwidth — at a glance.

Tally lives in the menu bar (no Dock icon) and renders current download/upload rates directly as the menu-bar label. Click it for a detailed window with connection info, network stats, and history.

## Features

- **Live throughput** in the menu bar, color-coded (down = blue, up = aqua)
- **Connection tab** — current interface, gateway, and link details
- **Network tab** — per-process bandwidth via `nettop`
- **Stats tab** — historical samples persisted with [GRDB](https://github.com/groue/GRDB.swift)
- **Connection quality scoring** from latency and path monitoring

## Requirements

- macOS 14 (Sonoma) or later
- Swift 6 toolchain (Xcode 16+)

## Build

```sh
./build.sh            # release build, assembles Tally.app
./build.sh debug      # debug build
```

`build.sh` compiles via Swift Package Manager and assembles a proper `.app` bundle (required for the `LSUIElement` menu-bar behavior), then ad-hoc signs it.

Run it:

```sh
open ./Tally.app
# or, for console logs:
./Tally.app/Contents/MacOS/Tally
```

## Develop

```sh
swift build           # plain SPM build
swift test            # run the test suite

./lint.sh             # SwiftFormat (apply) + SwiftLint
./lint.sh --check     # verify formatting without modifying (CI mode)
```

## Project layout

```
Sources/Tally/
  TallyApp.swift        MenuBarExtra entry point
  ViewModels/           NetworkViewModel
  Views/                DetailView + Connection / Network / Stats tabs, Settings
  Services/             sampling, latency/path monitoring, quality scoring, gateway lookup
  Store/                GRDB models + database
Tests/TallyTests/       unit tests
Resources/Info.plist    bundle metadata (LSUIElement)
```

## License

Personal use.
