# Platform caveats

## Where actions can appear

Unlike Nemo, we don't have the ability to change where an item appears. Finder hands an
extension exactly four menu kinds, and no more. Three of them are wired up:

- right-click on one or more selected items
- right-click on a window's empty space (the background)
- right-click on a sidebar item

At this time:
- The path bar cannot be supported
- The toolbar's `⋯` Actions button cannot be supported

These items do show up via quick actions if needed.

## Finder Sync

Finder Sync was designed by Apple primarily for file synchronization clients. This project
uses its supported contextual-menu API as a personal/open-source utility and does not target
the Mac App Store. Ordinary local folders and mounted volumes are monitored from `/`; virtual
Finder locations such as Recents and saved searches remain best-effort because Finder decides
whether their URLs belong to a monitored location.
