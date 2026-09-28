# Symlinks and dotfiles

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
