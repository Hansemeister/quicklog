# quicklog

macOS journaling overlay. Global hotkey → floating panel → type → `⌘↩` appends a
timestamped entry to today's markdown file.

## Requirements

- macOS 14+
- Xcode Command Line Tools (`swift`)
- [`just`](https://github.com/casey/just) (optional — see *Without just* below)

No third-party dependencies. SwiftUI + AppKit + Carbon only.

## Run

```sh
just run       # build, bundle, run in foreground (logs in terminal, ctrl-c quits)
just start     # build, bundle, launch detached like a normal app
just restart   # kill running instance + relaunch
just stop      # kill running instance
just install   # copy to /Applications
```

The app has no Dock icon (`LSUIElement`). It lives in the menu bar (pencil icon)
and on the hotkey.

### Without just

```sh
swift build -c release
mkdir -p .build/quicklog.app/Contents/MacOS
cp .build/release/quicklog .build/quicklog.app/Contents/MacOS/quicklog
cp Resources/Info.plist .build/quicklog.app/Contents/Info.plist
.build/quicklog.app/Contents/MacOS/quicklog
```

## Keys

| Key | Action |
| --- | --- |
| `⌘⇧Space` | toggle panel (global) |
| `⌘↩` | save entry |
| `⌘A` `⌘C` `⌘X` `⌘V` `⌘Z` | select all / copy / cut / paste / undo |
| `esc` or `⌘W` | hide panel |
| `⌘Q` | quit |

Change the hotkey in `Sources/quicklog/QuicklogApp.swift` → `registerHotkey()`.

## Window position

The panel remembers its frame (position + size) across launches, per screen
layout. Stored in `UserDefaults` under `quicklog.panelFrame`; if the saved frame
lands on a screen that is no longer attached, the panel re-centres.

Reset it:

```sh
defaults delete com.bigbrain.quicklog quicklog.panelFrame
```

## Storage

`~/Library/Application Support/quicklog/YYYY-MM-DD.md`

```md
# 2026-08-05

## 14:32
first entry, **markdown** allowed

## 15:01
- bullet
  - nested
```

Entries are split on lines matching exactly `## HH:mm`. Your own `##` headers
inside an entry are left alone.

- `just data` — open the folder
- `just today` — cat today's file
- `just nuke-data` — delete all entries (prompts)

## Markdown supported

Headers `#`/`##`/`###`, bullets `-`/`*`/`+` with 2-space nesting, `**bold**`,
`*italic*`, `` `code` ``. Preview toggle in the composer renders as you type.

## Manual test pass

1. `just run` — panel appears centred, cursor in the composer.
2. Type `# Day\n- **thing** done`, toggle *Preview* — header + bullet render.
3. `⌘↩` — entry appears above with a `HH:mm` stamp, composer clears.
4. `just today` in another terminal — the markdown is on disk.
5. `esc` hides. `⌘⇧Space` from another app brings it back on top, focused.
6. Sidebar: today is labelled *Today*. Add `~/Library/Application Support/quicklog/2026-08-01.md`
   by hand, reopen the panel — that day is listed and read-only.

## TODO

- **Edit / delete a past entry.** Currently append-only; past days are read
  only. Needs: inline editor per entry, rewrite of the whole day file (parse →
  mutate → write), and a decision on whether editing rewrites the `## HH:mm`
  stamp or keeps it. Workaround for now: edit the `.md` file directly
  (`just data`), then reopen the panel to pick up changes.
- Week/month grouping in the sidebar.
- Search.
- Configurable hotkey in-app (hardcoded to `⌘⇧Space` today).
- Draft is lost if the app quits before `⌘↩` — no draft persistence.

## Not implemented (per PLAN.md)

Sync, search, export, week/month sidebar grouping, editing past entries.

## Layout

```
Package.swift
Justfile
Resources/Info.plist
Sources/quicklog/
  QuicklogApp.swift      # entry point, app delegate, global hotkey, menu bar
  PanelController.swift  # floating NSPanel + root view
  EntryView.swift        # composer, entry list, markdown renderer
  SidebarView.swift      # day list
  StorageManager.swift   # flat .md read/write + JournalStore
```

Sources live under `Sources/quicklog/` rather than the repo root — SwiftPM
requires it.
