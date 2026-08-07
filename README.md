# quicklog

A journal you can reach without leaving what you're doing. Hit `⌘⇧Space`
anywhere, type the thought, `⌘↩`, `esc`. The panel floats above the app you were
in — no window switching, no Dock icon, no launch wait.

Entries land in plain markdown files you own, one per day:
`~/Library/Application Support/quicklog/YYYY-MM-DD.md`. Readable and greppable
without this app; no database, no sync, no account.

Built for capture speed first, review second: past days are browsable and
editable in the same panel, and a note can carry checkboxes for things to come
back to.

## Requirements

- macOS 14+
- Xcode Command Line Tools (`swift`)
- [`just`](https://github.com/casey/just) (optional — see *Without just*)

No third-party dependencies. SwiftUI + AppKit + Carbon only.

## Run

```sh
just run       # build, bundle, run in foreground (logs in terminal, ctrl-c quits)
just start     # build, bundle, launch detached like a normal app
just restart   # kill running instance + relaunch
just stop      # kill running instance
just install   # copy to /Applications
just test      # run storage tests
```

No Dock icon (`LSUIElement`) — the app lives in the menu bar (pencil icon) and on
the hotkey.

Only one instance runs at a time. Launching a second makes the running one show
its panel, then exits.

### Start at login

Menu-bar icon → **Start at Login**. macOS registers the bundle *at its current
path*, so install it first:

```sh
just install   # → /Applications/quicklog.app, then enable it from there
```

Enabling from `.build/quicklog.app` works but breaks on `just clean`.

### If the hotkey doesn't work

`⌘⇧Space` may already be taken (Spotlight, Alfred, input-source switching). The
menu-bar icon turns into a warning triangle and the menu says so; the app still
works from that menu. Change the combination in
`Sources/quicklog/QuicklogApp.swift` → `registerHotkey()`.

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
| `⌘↩` | save — the composer's draft, or the entry being edited |
| `↑` `↓` | at the top/bottom of a text box: step to the entry above/below |
| `esc` | cancel the edit, or hide the panel when not editing |
| `⌘W` | hide panel |
| `⌘A` `⌘C` `⌘X` `⌘V` `⌘Z` | select all / copy / cut / paste / undo (text) |
| `⌘Q` | quit |

`⌘↩` is a *Save Entry* item in the app menu, so it fires regardless of which text
box has focus. `⌘Z` is the text field's own undo — undoing an *entry* change uses
the arrow buttons in the header.

## Writing

The composer sits below the entry list, on today only. Type markdown, toggle
*Preview* to see it rendered, `⌘↩` to save. The entry appears above with a
`HH:mm` stamp and the composer clears.

Drag the handle above the composer to change the split. The height is remembered
across launches; neither pane can collapse (composer ≥110 pt, list ≥120 pt).

## Reviewing and editing

**Click an entry's text to edit it in place.** The caret lands at the end of the
note. Dragging to highlight text for copying doesn't trigger edit mode.
Right-click gives *Edit* and *Delete*.

`⌘↩` saves, `esc` cancels. After finishing with an entry the caret returns to the
composer, ready for the next note.

**Arrow keys step between notes.** From the composer, `↑` on the first line opens
the last entry with the caret at its end; `↑` again walks up its lines, then into
the entry above. `↓` mirrors it, and past the last entry returns to the composer.
Stepping away from an entry you changed saves it; an untouched one just closes.
The list scrolls to whatever opens.

There is no delete button — **clear the text and save** (the Save button relabels
itself to *Delete*). Deleted rows fade and collapse out of the list.

Edits rewrite that entry's **own day file** in place:

- the file keeps its `YYYY-MM-DD.md` name — an edited old entry never moves to
  today's file
- the `# YYYY-MM-DD` title, any hand-written preamble and every other entry's
  `## HH:mm` stamp are preserved
- the edited entry keeps its original timestamp

Deleting the last entry removes the file, so the day drops out of the sidebar —
unless the file has hand-written preamble text, which is kept.

## Undo / redo

Two arrow buttons in the header, right of the sidebar toggle. Covers saves,
edits, deletes and checkbox resolves; 50 steps deep; a new change clears the redo
stack; undo jumps the sidebar to the affected day. In-memory only — quitting
clears it.

## Checkboxes

Write a note you need to come back to as a task line:

```md
- [ ] send email to X
```

**Click the box to resolve it**, click again to reopen. Only that line is
rewritten to `- [x]`, boxes in the same entry resolve independently, and it's
undoable like any other change.

```sh
just todos   # every open `- [ ]` line across all day files, with file + line
```

Plain GitHub-style markdown — no separate todo store. Works with `-`, `*` and
`+`, and with nesting. Two shorthands are accepted as unchecked and normalised on
the first click: `- []` (nothing in the box) and `-[]` (no space after the
bullet). Dropping the space is only allowed before a box, so `-5 degrees` and
`-word` stay plain text.

## Sidebar

Day list, collapsible with the leftmost header button. Today is labelled *Today*.
Files dropped into the data folder by hand show up on the next open.

## Window

The panel remembers its position and size across launches, per screen layout. If
the saved frame lands on a screen that's gone, it re-centres.

```sh
defaults delete com.bigbrain.quicklog quicklog.panelFrame   # reset
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
- [x] resolved task
```

Entries split on lines matching exactly `## HH:mm`. Your own `##` headers inside
an entry are left alone.

- `just data` — open the folder
- `just today` — cat today's file
- `just todos` — list open `- [ ]` lines
- `just nuke-data` — delete all entries (prompts)

## Markdown supported

Headers `#`/`##`/`###`, bullets `-`/`*`/`+` with 2-space nesting, checkboxes
`- [ ]`/`- [x]`, `**bold**`, `*italic*`, `` `code` ``.

## Manual test pass

1. `just run` — panel appears centred, cursor in the composer.
2. Type `# Day\n- **thing** done`, toggle *Preview* — header + bullet render.
3. `⌘↩` — entry appears above with a `HH:mm` stamp, composer clears.
4. `just today` in another terminal — the markdown is on disk.
5. `esc` hides. `⌘⇧Space` from another app brings it back on top, focused.
6. Add `~/Library/Application Support/quicklog/2026-08-01.md` by hand, reopen the
   panel — that day is in the sidebar.
7. Click that old entry's text — editor opens, caret at the end, keyboard
   focused. Type, `⌘↩`. `cat` the file: same file name, same `# 2026-08-01`
   title, same `## HH:mm` stamp, new body. Caret is back in the composer.
8. Click it again → `⌘A`, delete, `⌘↩` (button reads *Delete*). The row fades and
   collapses; other entries intact.
9. Undo arrow — the entry is back. Redo — gone again. Both grey out on an empty
   stack.
10. Empty composer, `↑` — the last entry opens with the caret at its end. `↑`
    up through it and into the one above. `↓` back down and out to the composer.
    A long wrapped line must move the caret line by line before stepping away.
11. `↑` into an entry, type a word, `↑` again — the change is saved.
12. Drag the handle above the composer to both extremes — tracks the cursor
    without vibrating, neither pane collapses. `just restart` — split remembered.
13. Drag across an entry's text to highlight, `⌘C` — copies without entering edit
    mode.
14. Drag the panel to a corner, `just restart` — reopens in the same spot.
15. Save an entry with two boxes. Click the first — only it ticks, and the editor
    must *not* open. Click the text next to it — the editor opens. Undo — back to
    unticked.
16. Click the leftmost header button — the day list collapses, the button stays
    on the left. Click again to restore.

## Tests

```sh
just test
```

`Tests/main.swift` — 44 checks over storage: `##` headers inside an entry don't
split it, editing an old entry preserves file name/title/preamble/stamps, the
file layout, blank edit = delete, file-removal rules, per-line checkbox
resolve/reopen and both box shorthands.

A plain executable compiled against `StorageManager.swift`, not an XCTest target
— XCTest ships with Xcode and this builds on Command Line Tools alone. Exits
non-zero on failure.

UI behaviour (panel, hotkey, caret, arrow navigation, drag) isn't covered — see
the manual pass.

## Layout

```
Package.swift
Justfile
Resources/Info.plist
Sources/quicklog/
  QuicklogApp.swift      # entry point, single-instance lock, hotkey, menus
  PanelController.swift  # floating NSPanel + root view
  EntryView.swift        # composer, entry list, inline editor, markdown renderer
  SidebarView.swift      # day list
  StorageManager.swift   # flat .md read/write/edit/delete + JournalStore + TaskLine
Tests/main.swift         # storage + checkbox tests (just test)
```

## TODO

- Week/month grouping in the sidebar.
- Search.
- Configurable hotkey in-app (hardcoded to `⌘⇧Space`).
- Draft is lost if the app quits before `⌘↩` — no draft persistence.
- Undo history is in-memory; quitting clears it.
- New entries always go to today; no back-dating.
