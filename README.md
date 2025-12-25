# miniapp (CLI)

A small helper CLI for the MiniApp Host SDK integration.

## What it does

`miniapp host sdk install` injects an **Xcode Run Script build phase** into an iOS app target.
That script generates `miniapp-deps.json` into your app bundle resources at build time.

## Install (recommended)

This CLI is intended to be installed via Homebrew (tap + formula).

## Build from source

Requirements:
- macOS 13+
- Xcode Command Line Tools
- `python3` (for the build-phase script)

```sh
swift build -c release
./.build/release/miniapp --help
```

## Usage

```sh
miniapp host sdk install [--project <path/to/App.xcodeproj>] [--target <TargetName>] [--force]
```

Notes:
- If `--project` is not provided, the command searches the current directory tree for a `.xcodeproj`.
- If multiple app targets exist, pass `--target`.
- `--force` re-injects the build phase if already present.

## License

MIT. See LICENSE.

## Releasing

See RELEASING.md.
