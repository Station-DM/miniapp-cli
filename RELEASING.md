# Releasing miniapp

This repository publishes a Homebrew-installable CLI called `miniapp`.

## Prereqs

- You have push permission to `Station-DM/miniapp-cli`.
- Homebrew tap exists: `Station-DM/homebrew-miniapp`.

## Release steps

1. Ensure `main` is green locally
   - `swift build -c release`
   - `./.build/release/miniapp --help`

2. Choose a version (e.g. `v0.1.1`) and tag
   - `git tag -a v0.1.1 -m "miniapp v0.1.1"`
   - `git push origin v0.1.1`

3. Update the Homebrew formula
   - Download the tag tarball and compute sha256:
     - `curl -L https://github.com/Station-DM/miniapp-cli/archive/refs/tags/v0.1.1.tar.gz | shasum -a 256`
   - In `Station-DM/homebrew-miniapp`, update `Formula/miniapp.rb`:
     - `url` to the new tag
     - `sha256` to the new hash
   - Commit + push tap repo changes

4. Smoke test via brew
   - `brew update`
   - `brew upgrade miniapp` (or `brew install miniapp`)
   - `miniapp --help`

## Notes

- The formula builds from source via SwiftPM.
- If you ever change the executable name in `Package.swift`, update the formula `bin.install` and `test do` accordingly.
