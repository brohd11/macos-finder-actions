# Action files

The app recursively reads files ending in `.finder-action` from the config directory
(`~/.config/finder-actions` by default). A minimal action is:

```ini
[Finder Action]
Name=Copy Path
Exec=printf '%s' "$1" | pbcopy
Selection=single
Extensions=any;
```

## Fields

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

## Extension tokens

Extension tokens are case-insensitive:

- `any;` matches every file and folder and cannot be combined with other tokens.
- `nodirs;` matches all non-folder items and cannot be combined with other tokens.
- `dir;` matches folders and may be combined with extensions, such as `dir;pdf;`.
- `none;` matches extensionless files.
- `jpg;png;` requires every selected file to have one of those extensions.

App bundles and other Finder packages count as files, so `Extensions=app;` can target
applications. Invalid and unknown keys are errors: the action is hidden and the dashboard
shows the exact file and line.

See [`Examples`](../Examples) for copy-path and new-file configurations, and
[Execution](execution.md) for how `Exec` receives the selection.
