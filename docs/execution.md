# Execution

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

Existing shell scripts can be called unchanged from an `Exec` line.

## Environment

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

## Background actions

For a background action, use `Selection=none`; it receives no positional paths and can use
`$FINDER_ACTION_DIRECTORY`. `Selection=any` makes the same action available both with a
selection and on the folder background.

## Permissions

If your executed scripts need access for their process, i.e. using `osascript` to control
Finder, the background runner will ask for that permission too.
