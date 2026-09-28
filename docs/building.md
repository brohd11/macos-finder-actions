# Building from source

- macOS 13 or newer
- Full Xcode (Command Line Tools alone cannot package a Finder extension)

No Apple developer account is needed. Builds are ad-hoc signed by default.

```sh
./build.sh
```

That produces `dist/Finder-Actions.zip` and its checksum, running the same
`scripts/package.sh` the release workflow uses. Pass an explicit version and build
number if you want them: `./build.sh 0.2.0 12`.

`swift test` runs the shared-core test suite.

## Icons

Each bundle's icon is generated from the vector source next to it in `Resources/Icons`.
The `.icns` outputs are committed, so a normal build needs no icon tooling; rerun
`scripts/make-icons.sh` after editing an SVG.

## Signing and bundle identifiers

The bundle identifiers and background runner Mach service are derived from
`BUNDLE_ID_PREFIX`; no App Group or provisioning profile is required. If you do have
an Apple development team and want Xcode to sign with it, copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and set your
team ID and reverse-DNS prefix there.

## Background runner

The background runner owns the action catalog and shares parsed snapshots with the app and
Finder extension. Custom configuration directories therefore do not require symlinks or
additional Finder-extension filesystem entitlements.

The background runner is stored as a per-user LaunchAgent in `~/Library/LaunchAgents`.
Disable it from the dashboard before permanently removing the app.
