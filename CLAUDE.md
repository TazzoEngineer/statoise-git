# CLAUDE.md

Guidance for Claude Code when working in this repository.

## What this is

Statoise Git is a macOS Finder-integrated Git client (TortoiseGit-style), written in Swift +
AppKit. It consists of a main app and a sandboxed FinderSync extension.

## Build commands

The Xcode project is **generated** — never edit `StatoiseGit/StatoiseGit.xcodeproj` by hand.
Change `StatoiseGit/project.yml` and regenerate.

```sh
make generate   # xcodegen generate (run after touching project.yml or adding files)
make build      # generate + xcodebuild (Debug)
make run        # build, copy to ~/Applications, re-register with LaunchServices, launch
make release    # Release configuration
make dmg        # Release + scripts/create-dmg.sh
make clean      # rm -rf build/ + xcodebuild clean
```

Run the unit tests the way CI does:

```sh
cd StatoiseGit && xcodebuild -project StatoiseGit.xcodeproj -scheme StatoiseGit \
  -configuration Debug -destination "platform=macOS" -derivedDataPath ../build/DerivedData \
  test -only-testing:StatoiseGitTests \
  CODE_SIGN_IDENTITY="-" CODE_SIGNING_REQUIRED=NO CODE_SIGNING_ALLOWED=YES
```

`-only-testing:StatoiseGitTests` matters: the UI tests need a running app and are not part of
the CI gate.

## Architecture

Two bundles, one shared source tree:

| Target | Bundle ID | Sources |
|---|---|---|
| `StatoiseGit` (app) | `com.statoisegit.app` | `Sources/App`, `Sources/GitOperations`, `Sources/Shared` |
| `StatoiseGitFinderExtension` | `com.statoisegit.app.FinderExtension` | `FinderExtension`, `Sources/GitOperations`, `Sources/Shared` |

**The extension cannot run git.** It is sandboxed, so every action it offers is dispatched to
the main app as a URL: `statoisegit://<action>?path=<repo-or-file-path>[&file=…][&files=a,b]`.
`FinderSyncExtension.openMainApp(action:path:extraParams:)` builds the URL;
`AppDelegate.handleURLEvent` routes it. Adding a context-menu action means touching **both**
sides plus the `switch url.host` in `AppDelegate`.

**All git invocation goes through `Sources/GitOperations/GitCommandRunner.swift`** (async/await,
`GitCommandRunner.shared`). Do not spawn `git` anywhere else. Two long-standing hazards this
file already handles — preserve them when editing:

- `/usr/bin/git` is an `xcrun` shim that fails under App Sandbox, so the real binary path is
  resolved explicitly (see `RepositoryPreferences.defaultGitPath`, user-overridable in Preferences).
- Paths beginning with `.` and paths inside submodules need explicit `--` separators and
  repository-root resolution; `GitDotPathTests` and `GitSubmoduleTests` cover these.

**App ↔ extension state** lives in `Sources/Shared/RepositoryPreferences.swift`: the monitored
repository list and the per-directory status cache are written as JSON under
`/Users/Shared/StatoiseGitShared` (a plain shared directory rather than an App Group, because the
sandboxed extension is granted a read-only temporary exception to exactly that path in
`FinderExtension/StatoiseGitFinderExtension.entitlements`). Repositories under `~/Documents`,
`~/Desktop` and `~/Downloads` need the home-relative exceptions in the same file — without them
Finder silently drops the context menu and badges.

## Conventions

- Swift 5.9, macOS 13.0 deployment target, AppKit (no SwiftUI in this codebase).
- Window controllers are plain `NSWindowController` subclasses in `Sources/App`, one file each.
- Surface git failures through `GitErrorAlert` rather than swallowing them — the dialog exists
  so unknown failures are reportable next time they happen.
- Overlay icons are original artwork in `Resources/OverlayIcons` and
  `FinderExtension/OverlayIcons` (both copies are needed; the extension loads its own).
  `scripts/generate_icons.py` regenerates them.
- Commit messages in this repository are a mix of Japanese and English; either is fine.

## Gotchas

- After `make run`, changes to the **extension** often need Finder restarted (or the extension
  toggled off/on in System Settings → General → Login Items & Extensions) before they take effect.
- Builds are ad-hoc signed (`CODE_SIGN_IDENTITY="-"`); there is no Developer ID or notarization
  in this repository, and `scripts/install.sh` runs `xattr -cr` for that reason.
- `.github/workflows/build.yml` patches the version into `Sources/App/Info.plist` at build time — the committed
  values (`0.0.0` / `local.0`) are placeholders, don't "fix" them.
