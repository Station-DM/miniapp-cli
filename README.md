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

Release/version note:
- `miniapp --version` prints the embedded constant in `Sources/Version.swift`.
- When publishing a new Homebrew release, bump `miniAppCLIVersion` to match the tag (e.g. `v0.1.1`) before tagging.
- If you use `sync_cli_to_public.sh`, you can also set `MINIAPP_CLI_VERSION` when syncing to stamp the public repo before committing.

## Usage

```sh
miniapp host sdk install [--project <path/to/App.xcodeproj>] [--target <TargetName>] [--force]
```

Notes:
- If `--project` is not provided, the command searches the current directory tree for a `.xcodeproj`.
- If multiple app targets exist, pass `--target`.
- `--force` re-injects the build phase if already present.
- Run `miniapp --version` to print the CLI semantic version (kept in sync with `miniAppCLIVersion` in `main.swift`).

## License

Add a LICENSE file before publishing publicly.
