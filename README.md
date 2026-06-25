# miniapp (CLI)

A small helper CLI for the MiniApp Host SDK integration.

## What it does

`miniapp host sdk install` injects an **Xcode Run Script build phase** into an iOS app target.
That script generates `miniapp-deps.json` into your app bundle resources at build time.

## Install (recommended)

```sh
brew tap station-dm/miniapp
brew trust station-dm/miniapp
brew install miniapp
```

Upgrade to the latest version:

```sh
brew update && brew upgrade miniapp
```

## Build from source

Requirements:
- macOS 13+
- Xcode Command Line Tools
- `python3` (for the build-phase script)

```sh
swift build -c release
./.build/release/miniapp --help
```

## Release & Upgrade Guide

To release a new version of the CLI and update it in Homebrew:

1. **Bump Version**: Update the `miniAppCLIVersion` constant in `Sources/Version.swift` (e.g. to `v0.1.5`).
2. **Tag and Push**: Commit the change, tag it (`git tag v0.1.5`), and push the tag to this remote repository (`git push origin main --tags`).
3. **Update Homebrew Tap** (choose one):
   - **自动化**：直接运行 `./update_homebrew_tap.sh`，脚本会自动读取版本号、计算 sha256、更新 Formula 并推送。
   - **手动**：
     - Go to the `Station-DM/homebrew-miniapp` tap repository.
     - Edit `Formula/miniapp.rb`.
     - Update the `url` to the new tag's tarball (e.g., `https://github.com/Station-DM/miniapp-cli/archive/refs/tags/v0.1.5.tar.gz`).
     - Run `curl -sL <the-url-above> | shasum -a 256` to calculate the new hash.
     - Update the `sha256` field with the new hash.
     - Commit and push the updated formula.
   - Users can now run `brew upgrade miniapp` to get the latest version.

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
