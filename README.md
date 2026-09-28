# Finder Actions

After coming to macOS from Linux Mint, I really missed Nemo's ability to add custom items to the context menu.
I started using quick actions via automator, which was fine, but not ideal. This app provides a system similar to Nemo Actions in Finder

Using a FinderSync plugin, you can get closer to what Nemo provides. I'm using `.finder-action` files, that are similar to the config style of Nemo Actions

Benefits over quick actions:
- plain text config; good for dotfiles
- actions can be direct menu items or nested into user-defined groups
- actions disappear when the selection count, file kind, or extension does not match
- empty-space/background and Finder sidebar actions are supported

Finder only exposes three menus to an extension, so unlike Nemo you can't choose where an item appears — see
[Platform caveats](docs/platform-caveats.md).

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

If you don't want to download and de-quarantine, you can [build from source](docs/building.md).

To uninstall, disable the background runner from the dashboard before removing the app.

## Quick example

Save this as `~/.config/finder-actions/copy-path.finder-action`, then right-click a file in Finder:

```ini
[Finder Action]
Name=Copy Path
Exec=printf '%s' "$1" | pbcopy
Selection=single
Extensions=any;
```

More in [`Examples`](Examples) and the [action file reference](docs/action-files.md).

## Documentation

- [Action files](docs/action-files.md) — fields and extension tokens
- [Execution](docs/execution.md) — arguments, environment, background actions
- [Symlinks and dotfiles](docs/dotfiles.md) — managing actions with Stow and friends
- [Platform caveats](docs/platform-caveats.md) — available menus and Finder Sync limits
- [Building](docs/building.md) — build from source, tests, signing, background runner
