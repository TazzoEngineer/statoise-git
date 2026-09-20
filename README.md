# Statoise Git

*English | [日本語](README.ja.md)*

[![Build](https://github.com/TazzoEngineer/statoise-git/actions/workflows/build.yml/badge.svg)](https://github.com/TazzoEngineer/statoise-git/actions/workflows/build.yml)

A Finder-integrated Git client for macOS — TortoiseGit-style workflow, native AppKit app.

Statoise Git puts Git where you already work: right-click any file or folder in Finder to
commit, diff, or browse history, and see each file's status as an icon overlay without
opening a terminal.

> Status: early / preview. Builds are unsigned (ad-hoc), so macOS will ask you to approve
> the app on first launch.

## Features

- **Finder context menu** — Commit, Diff, Log, Pull, Push, Fetch, Add, Stash (save / save with
  message / pop / list), Submodule update, Reset --hard, Clean -xdf
- **Icon overlays** — Normal, Modified, Added, Deleted, Conflict, Unversioned, Ignored, Locked,
  Read-only badges drawn on files and folders in Finder
- **Commit window** — stage/unstage, per-file diff, revert and delete from the file list,
  "Show unmodified" toggle and a live file count
- **Log window** — commit graph rendering, per-commit file list, per-file diff, file history
- **Diff window** — built-in viewer, plus launching an external diff tool (e.g. Meld)
- **Submodule aware** — status, diff and commit routing all handle submodule paths correctly
- **Preferences** — register the repositories to monitor, pick the `git` binary and the
  external diff tool, and jump straight to System Settings → Login Items & Extensions

## Requirements

- macOS 13.0 or later
- Xcode 15 or later
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (`brew install xcodegen`) — the Xcode
  project is generated from `StatoiseGit/project.yml`

## Build and run

```sh
make build     # generate the Xcode project and build (Debug)
make run       # build, install into ~/Applications, and launch
make release   # build with the Release configuration
make dmg       # build Release and package a .dmg
make clean     # remove build artifacts
```

After the first launch, enable the Finder extension in
**System Settings → General → Login Items & Extensions → Finder Extensions**, then add your
repositories in the app's Preferences window.

## How it works

The app ships two bundles that talk to each other:

- `Statoise Git.app` (`com.statoisegit.app`) — the UI: Preferences, Commit, Log and Diff windows
- `StatoiseGitFinderExtension` (`com.statoisegit.app.FinderExtension`) — a sandboxed FinderSync
  extension that draws the badges and builds the context menu

The extension is sandboxed and cannot run Git itself, so choosing a menu item opens a
`statoisegit://<action>?path=…` URL that the main app handles (`commit`, `log`, `diff`,
`pull`, `push`, `fetch`, `add`, `stash-save`, `stash-save-prompt`, `stash-pop`, `stash-list`,
`reset-hard`, `clean-xdf`, `submodule-update`). Status is computed in the app and shared with
the extension through a cache directory under `/Users/Shared/StatoiseGitShared`.

## Repository layout

```
StatoiseGit/
  project.yml                  XcodeGen project definition
  Sources/App/                 AppKit UI, URL scheme routing, git error alerts
  Sources/GitOperations/       GitCommandRunner — every git invocation lives here
  Sources/Shared/              RepositoryPreferences — app ↔ extension shared state
  FinderExtension/             FinderSync extension and its overlay icons
  Resources/                   App icon and overlay icon assets
  Tests/                       Unit tests for git operations
  UITests/                     UI tests for the commit window
scripts/                       Icon generation, DMG packaging, install helper
.github/workflows/build.yml    CI: generate, build, unit test, package artifact
Makefile                       Everyday build commands
```

## License

[MIT](LICENSE)
