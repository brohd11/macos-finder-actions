# Finder Actions

After coming to macOS from Linux Mint, I really missed Nemo's ability to add custom items to the context menu.
I started using quick actions via automator, which was fine, but not ideal. This app provides a system similar to Nemo Actions in Finder

Using a FinderSync, you can get closer to what Nemo provides. I'm using `.finder-action` files, that are similar to the config style of Nemo Actions

Benefits over quick actions:
- plain text config; good for dotfiles
- actions can be direct menu items or nested into user-defined groups
- actions disappear when the selection count, file kind, or extension does not match
- empty-space/background and Finder sidebar actions are supported

Unlike Nemo, we don't have the ability to change where an item appears. Finder only exposes
three menus to an extension: right-click on items, right-click on empty space, and right-click
in the sidebar. The path bar and the toolbar's `⋯` Actions button are off limits — see
[Platform caveats](#platform-caveats).

## Install

macOS 13 or newer

```sh
curl -fsSL https://raw.githubusercontent.com/brohd11/macos-finder-actions/main/install.sh | sh
```

The installer puts **Finder Actions.app** in `/Applications` and replaces an existing copy.

I don't have a paid Apple Developer ID, so the release is not notarized. The build is ad-hoc signed during the github release build.
Depending on your macOS version you either select "Open Anyway" when trying to open the app, or de-quarantine the app:
```
xattr -dr com.apple.quarantine "/Applications/Finder Actions.app"
```
The dashboard will have you enable the Finder Extension as well as a per-user background runner for script execution.
If you are having permission check popups occur after reboot, allowing the app "Full Disk Access", can help with that, otherwise it should be a once per reboot prompt.

Note, if your executed scripts need access for their process ie. using osascript to control Finder, the runner will ask for that permission too.

If you don't want to download and de-quarantine, you can build with Xcode or the included build script.


## Action files

The app recursively reads files ending in `.finder-action`. A minimal action is:

```ini
[Finder Action]
Name=Copy Path
Exec=printf '%s' "$1" | pbcopy
Selection=single
Extensions=any;
```

Current fields:

| Key | Meaning | Default |
| --- | --- | --- |
| `Name` | Finder menu label; required | — |
| `Exec` | zsh command; required | — |
| `Selection` | `none`, `single`, `multiple`, `notnone`, `any`, or an exact nonnegative number | `notnone` |
| `Extensions` | Semicolon list of extensions or the tokens below | `any;` |
| `Group` | Slash-delimited nested menu path; empty means top level | empty |
| `Order` | Signed integer used to order actions and groups | `1000` |
| `SeparatorBefore` | `true` or `false` | `false` |
| `Icon` | SF Symbol name | none |
| `Active` | `true` or `false` | `true` |

Extension tokens are case-insensitive:

- `any;` matches every file and folder and cannot be combined with other tokens.
- `nodirs;` matches all non-folder items and cannot be combined with other tokens.
- `dir;` matches folders and may be combined with extensions, such as `dir;pdf;`.
- `none;` matches extensionless files.
- `jpg;png;` requires every selected file to have one of those extensions.

App bundles and other Finder packages count as files, so `Extensions=app;` can target
applications. Invalid and unknown keys are errors: the action is hidden and the dashboard
shows the exact file and line.

### Item Execution

The app executes the command as:

```text
/bin/zsh -c <Exec> <action-id> <selected-path-1> <selected-path-2> ...
```

Inside `Exec`, selected paths are `"$@"`, and `$0` is the action ID. Paths are
never substituted into the command source, so quotes, whitespace, Unicode, and newlines
remain individual arguments. Add `"$@"` explicitly when the called script should receive
the selection:

```ini
Exec="$FINDER_ACTION_CONFIG_DIR/scripts/resize.sh" --max 2000 "$@"
```

Each process also has access to:

- `FINDER_ACTION_ID`
- `FINDER_ACTION_NAME`
- `FINDER_ACTION_DIRECTORY`
- `FINDER_ACTION_CONFIG`
- `FINDER_ACTION_CONFIG_DIR`
- `FINDER_ACTION_SELECTION_COUNT`

The working directory is the containing Finder directory, or the clicked directory for
a background action. The non-login shell gets a stable PATH containing `/opt/homebrew/bin`,
`/usr/local/bin`, and the standard Apple paths. Source your own environment from `Exec` if
an action needs more.

For a background action, use `Selection=none`; it receives no positional paths and can use
`$FINDER_ACTION_DIRECTORY`. `Selection=any` makes the same action available both with a
selection and on the folder background.

See [`Examples`](Examples) for copy-path and new-file configurations. Existing shell
scripts can be called unchanged from an `Exec` line.

### Where actions can appear

Finder hands an extension exactly four menu kinds, and no more. Three of them are wired up:

- right-click on one or more selected items
- right-click on a window's empty space (the background)
- right-click on a sidebar item

At this time:
- The path bar cannot be supported
- The toolbar's `⋯` Actions button cannot be supported

These items do show up via quick actions if needed.


### Symlinks and dotfiles

The config directory is read recursively with symlinks followed, so it can be managed
by GNU Stow or any other dotfiles tool. All three shapes work:

- `~/.config/finder-actions` itself a symlink to a directory
- individual `.finder-action` files symlinked into a real directory
- symlinked subdirectories, for nested `Group` menus

An action's ID is its path relative to the config directory so IDs and run
history stay stable whichever of those layouts you use. `FINDER_ACTION_CONFIG` and
`FINDER_ACTION_CONFIG_DIR` are the *resolved* paths, so a helper script stored beside an
action in your repo is found:

```ini
Exec="$FINDER_ACTION_CONFIG_DIR/scripts/resize.sh" --max 2000 "$@"
```

Broken links are reported in the dashboard's **Problems** tab and skipped; the rest of
your actions keep working. Symlink cycles are detected and skipped. Hidden entries
(`.git`, `.DS_Store`) are ignored.

The **Choose…** directory picker is for pointing config at a directory you would rather not symlink.


## Platform caveats

Finder Sync was designed by Apple primarily for file synchronization clients. This project
uses its supported contextual-menu API as a personal/open-source utility and does not target
the Mac App Store. Ordinary local folders and mounted volumes are monitored from `/`; virtual
Finder locations such as Recents and saved searches remain best-effort because Finder decides
whether their URLs belong to a monitored location.


## Build from source

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

The bundle identifiers and background runner Mach service are derived from
`BUNDLE_ID_PREFIX`; no App Group or provisioning profile is required. If you do have
an Apple development team and want Xcode to sign with it, copy
`Config/Local.xcconfig.example` to `Config/Local.xcconfig` (gitignored) and set your
team ID and reverse-DNS prefix there.

The background runner owns the action catalog and shares parsed snapshots with the app and
Finder extension. Custom configuration directories therefore do not require symlinks or
additional Finder-extension filesystem entitlements.

The background runner is stored as a per-user LaunchAgent in `~/Library/LaunchAgents`.
Disable it from the dashboard before permanently removing the app.
