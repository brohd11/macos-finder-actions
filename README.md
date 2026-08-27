# Finder Actions

After coming to macOS from Linux Mint, I really missed Nemo's ability to add custom items to the context menu.
I started using quick actions via automator, which was fine, but not ideal. This app provides a system similar to Nemo Actions in Finder

Using a FinderSync, you can get closer to what Nemo provides. I'm using `.finder-action` files, that are similar to the config style of Nemo Actions

Benefits over quick actions:
- plain text config; good for dotfiles
- actions can be direct menu items or nested into user-defined groups
- actions disappear when the selection count, file kind, or extension does not match
- empty-space/background and Finder sidebar actions are supported

Unlike Nemo, we don't have the ability to change where an item appears.

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
The dashboard will also ask to enable the Finder extension, as well as allowing background processes for the script execution.
I also find allowing the app "Full Disk Access", will stop any permission popups that occur after a reboot.

Alot of access, but it's open source. Feel free to inspect for shenanigans. If you don't want to download and de-quarantine, you can build with Xcode.


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

Inside `Exec`, selected paths are therefore `"$@"`, and `$0` is the action ID. Paths are
never substituted into the command source, so quotes, whitespace, Unicode, and newlines
remain individual arguments. Add `"$@"` explicitly when the called script should receive
the selection:

```ini
Exec="$FINDER_ACTION_CONFIG_DIR/scripts/resize.sh" --max 2000 "$@"
```

Each invocation also receives:

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

See [`Examples`](Examples) for copy-path and new-file configurations. Existing scripts
from `../macos-quick-actions/` can be called unchanged from an `Exec` line; their old guard
blocks become redundant because Finder Actions filters the menu before launch.


## Platform caveats

Finder Sync was designed by Apple primarily for file synchronization clients. This project
uses its supported contextual-menu API as a personal/open-source utility and does not target
the Mac App Store. Ordinary local folders and mounted volumes are monitored from `/`; virtual
Finder locations such as Recents and saved searches remain best-effort because Finder decides
whether their URLs belong to a monitored location.

## Build from source

- macOS 13 or newer
- Full Xcode (Command Line Tools alone cannot package a Finder extension)
- An Apple development team selected for local code signing

Set up signing once:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

**Note:** `Config/Local.xcconfig` is gitignored.

Edit `Config/Local.xcconfig` with your team ID and a unique reverse-DNS prefix, then:

1. Open `FinderActions.xcodeproj` in Xcode.
2. Select the **FinderActions** scheme and run it.
3. In the dashboard, enable the background runner.
4. Choose **Manage** beside Finder extension and enable Finder Actions in System Settings.
5. Allow failure notifications if desired.
6. Put one or more `.finder-action` files below `~/.config/finder-actions/`.

The bundle identifiers and background runner Mach service are derived from
`BUNDLE_ID_PREFIX`; no App Group or provisioning profile is required.
