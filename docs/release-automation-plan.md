# Release Automation Plan (Option A) — TODO

> Status: **planned, not implemented.** Recorded for later. The current
> release process is still the manual one in `README.md` → "Release & Upgrade Guide".

## Goal

Keep the `brew install miniapp` consumption UX exactly as-is, but remove the
manual Homebrew release dance. After this is implemented, cutting a release
should be just:

```sh
# bump Sources/Version.swift, commit, then:
git tag v0.1.9
git push origin main --tags
```

Everything after the tag push (build → compute sha256 → edit the tap Formula →
push the tap) is done by CI. This mirrors how `pod` releases feel: publish =
push, the rest is automated.

## Current pain (what we are replacing)

Manual `./update_homebrew_tap.sh` after every release:
- download the tag tarball,
- compute sha256,
- `perl`-edit `../homebrew-miniapp/Formula/miniapp.rb`,
- commit and push the tap repo.

This requires the tap repo cloned as a sibling dir and is run by hand.

## Target design

A GitHub Actions workflow in **this** repo, triggered on `v*` tag push, that
reproduces `update_homebrew_tap.sh` against the tap repo:

1. Trigger: `on.push.tags: ['v*']`.
2. Resolve version from the tag (or from `Sources/Version.swift`).
3. Download `https://github.com/Station-DM/miniapp-cli/archive/refs/tags/<tag>.tar.gz`
   and compute `shasum -a 256`.
4. Check out the tap repo `Station-DM/homebrew-miniapp`.
5. Update `Formula/miniapp.rb` `url` + `sha256` (reuse the `perl` lines from
   `update_homebrew_tap.sh`).
6. Commit + push to the tap's `main`.

The logic already exists in `update_homebrew_tap.sh` — the workflow is mostly
a thin wrapper that supplies the tap checkout and credentials.

## Prerequisites / open questions (resolve before implementing)

- **Cross-repo push credentials.** The Action must push to
  `Station-DM/homebrew-miniapp`. Options:
  - A PAT (repo scope, write to the tap) stored as an Actions secret
    (e.g. `HOMEBREW_TAP_TOKEN`) and used to clone/push the tap, **or**
  - a GitHub App / deploy key scoped to the tap.
  - The default `GITHUB_TOKEN` cannot push to a different repo, so one of the
    above is required.
- **Tarball availability timing.** GitHub usually generates the tag tarball
  immediately, but add a short retry around the sha256 step (the manual script
  already fails loudly if the tarball is missing).
- **Keep `update_homebrew_tap.sh`** as the manual fallback / single source of
  the perl-edit logic; the workflow should call or mirror it rather than
  duplicate it.

## Alternative considered (not chosen)

- **Mint distribution** (`mint install Station-DM/miniapp-cli@<tag>`): drops
  Homebrew entirely — no Formula, no sha256, no tap; release = `git tag && push`.
  Rejected for now because the `brew install` chain is already shipped and in
  use; revisit if maintaining the tap becomes the bottleneck.
