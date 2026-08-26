# Finder Actions

Finder Actions is a dotfile-driven Finder Sync extension for putting your own
shell actions in Finder's right-click menu. It is intentionally closer to Linux
Mint's Nemo Actions than Automator Quick Actions:

- actions can be direct menu items or nested into user-defined groups;
- actions disappear when the selection count, file kind, or extension does not match;
- empty-space/background and Finder sidebar actions are supported;
- selected paths arrive as shell positional arguments without command-string interpolation;
- configuration remains plain text under `~/.config/finder-actions/`;
- failures produce notifications and every run has bounded stdout/stderr history.

Finder controls where an extension's contributed block appears relative to its own
commands. Finder Actions controls ordering, separators, and grouping inside that block,
but cannot insert an item between arbitrary Apple-provided commands.

## Requirements and first build

- macOS 13 or newer
- Full Xcode (Command Line Tools alone cannot package a Finder extension)
- An Apple development team selected for local code signing

Set up signing once:

```sh
cp Config/Local.xcconfig.example Config/Local.xcconfig
```

Edit `Config/Local.xcconfig` with your team ID and a unique reverse-DNS prefix, then:

1. Open `FinderActions.xcodeproj` in Xcode.
2. Select the **FinderActions** scheme and run it.
3. In the dashboard, enable the background runner.
4. Choose **Manage** beside Finder extension and enable Finder Actions in System Settings.
5. Allow failure notifications if desired.
6. Put one or more `.finder-action` files below `~/.config/finder-actions/`.

The app group is derived from `BUNDLE_ID_PREFIX`. Xcode's automatic signing registers
that group for the selected team. The ignored `Local.xcconfig` keeps developer-specific
values out of dotfiles and source control.

## Action files

The runner recursively reads UTF-8 files ending in `.finder-action`. A minimal action is:

```ini
[Finder Action]
Name=Copy Path
Exec=printf '%s' "$1" | pbcopy
Selection=single
Extensions=any;
```

The complete v1 schema is:

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

### Shell contract

The runner executes the command as:

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

## Runtime model and security

The sandboxed Finder extension only reads a normalized action snapshot and sends an action
ID plus the current Finder paths over an app-group XPC service. A user-controlled launch
agent reloads the source configs, revalidates every request, and runs `/bin/zsh` without a
sandbox. It never runs as root and does not invoke `sudo`.

Configs are trusted code: anyone who can edit them can execute commands as your account.
macOS privacy controls still apply. Scripts that read protected Desktop, Documents, mail,
browser, or other data may require Files and Folders or Full Disk Access permission for
Finder Actions.

The runner executes up to four actions concurrently. Logs retain at most 200 runs for 30
days and 50 MB total; stdout and stderr are each capped at 1 MB per run while excess output
continues to be drained.

## Development and verification

The shared code is also a Swift package, allowing parser and behavior checks without
installing the extension:

```sh
swift run finder-actions-selftest
```

With Xcode installed, use **Product → Test** or:

```sh
xcodebuild -project FinderActions.xcodeproj -scheme FinderActions test
```

The repository includes XCTest coverage for parsing, matching, nested ordering, and log
pruning. The SwiftPM self-test covers the same critical path for environments whose Command
Line Tools do not ship XCTest.

## Platform caveats

Finder Sync was designed by Apple primarily for file synchronization clients. This project
uses its supported contextual-menu API as a personal/open-source utility and does not target
the Mac App Store. Ordinary local folders and mounted volumes are monitored from `/`; virtual
Finder locations such as Recents and saved searches remain best-effort because Finder decides
whether their URLs belong to a monitored location.
