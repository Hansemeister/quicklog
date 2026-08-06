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
just test      # run storage tests
```

The app has no Dock icon (`LSUIElement`). It lives in the menu bar (pencil icon)
and on the hotkey.

**Only one instance can run.** Launching a second one makes the running instance
show its panel, then exits. Enforced with an advisory `flock` on
`~/Library/Application Support/quicklog/.instance.lock` — the kernel drops it
when the process dies, so a crash can't leave it stuck, and it works for both
`just run` (bare binary) and `just start` (bundle).

### Start at login

Menu-bar icon → **Start at Login** (a checkmark shows the current state). Uses
`SMAppService.mainApp`, so macOS registers the bundle *at its current path*:

```sh
just install   # → /Applications/quicklog.app, then enable it from there
```

Enabling it from `.build/quicklog.app` works but breaks on `just clean`. If
macOS refuses the registration, an alert says so instead of failing silently.

### If the hotkey doesn't work

`⌘⇧Space` can already be taken (Spotlight, Alfred, input-source switching). When
registration fails the menu-bar icon turns into a warning triangle and the menu
says so — the app still works, open it from that menu. Change the combination in
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
| `⌘↩` | save entry |
| `⌘A` `⌘C` `⌘X` `⌘V` `⌘Z` | select all / copy / cut / paste / undo (text) |
| `esc` or `⌘W` | hide panel |
| `⌘Q` | quit |

While editing an entry: `⌘↩` saves, the *Cancel* button discards.

`⌘Z` is the text field's own undo. Undoing an *entry* change (save/edit/delete)
is done with the two arrow buttons at the top of the window, not a shortcut.

## Undo / redo

Two arrow buttons at the top of the window, right of the sidebar toggle. They
grey out when there is nothing to undo/redo, and show a text label next to them
on hover. Covers saves, edits, deletes and checkbox resolves; 50 steps deep; a
new change clears the redo stack. Undo jumps the sidebar to the affected day.

Implemented as whole-file snapshots (`before`/`after` text per change) rather
than per-entry diffs — a day file is a few KB, and it can't drift out of sync
with the parser. The stack is in-memory only, so it resets when the app quits.

## Editing and deleting

**Click an entry's text to edit it.** The editor opens focused with the caret at
the end of the note, so you can type straight away. Dragging to highlight text
for copying does not trigger edit mode — the tap gesture has a movement
threshold. Right-click gives *Edit* and *Delete*. Hovering an entry tints its
background to show it's clickable. Clicking a checkbox resolves it instead of
opening the editor — see *Checkboxes*.

The inline editor is a plain SwiftUI `TextEditor`. `focusEditorAtEnd` finds the
underlying `NSTextView`, makes it first responder and puts the caret at the end.
SwiftUI's own `@FocusState` + `TextSelection` route was tried first and lost the
race with the editor's own setup, which parks the caret at offset 0.

`⌘↩` saves and `esc` cancels the edit; `esc` is routed through
`QuicklogPanel.onCancel`, so it cancels an open edit and only hides the panel
when nothing is being edited.

There is no delete button — **clear the text in the editor and save to delete
the entry** (the Save button relabels itself to *Delete* when the text is
empty). Deleted rows fade and collapse out of the list.

Edits rewrite **that entry's own day file** in place:

- the file keeps its `YYYY-MM-DD.md` name — an edited old entry never moves to
  today's file
- the `# YYYY-MM-DD` title, any hand-written preamble, and every other entry's
  `## HH:mm` stamp are preserved
- the edited entry keeps its original timestamp

Deleting the last entry removes the file so the day drops out of the sidebar —
unless the file has hand-written preamble text, which is kept.

Entry identity is content-derived (`HH:mm#occurrence#body`) rather than a fresh
UUID per parse, so surviving rows keep their identity across a reload and only
the deleted row animates.

## Checkboxes

Write a note you need to come back to as a task line:

```md
- [ ] send email to X
```

It renders as an unchecked box. **Click the box to resolve it** (click again to
reopen). The cursor turns into a pointing hand over a box. Only that line is
rewritten to `- [x]` in the day file, boxes in the same entry resolve
independently, and it's undoable like any other change.

```sh
just todos   # every open `- [ ]` line across all day files, with file + line
```

Plain GitHub-style markdown — no separate todo store, no new file format. Works
with `-`, `*` and `+`, and with nesting. A box needs a space after the bullet
(`- [ ]`, not `-[ ]`).

The box can't own a click gesture of its own. The entry body's click-to-edit
gesture is `simultaneousGesture` (so text selection still works), which means a
child gesture would fire *as well* and open the editor on top of the toggle. So
the row's single tap handler checks which box the cursor is over — tracked via
`onHover` — and either resolves that box or opens the editor. Cursor pushes and
pops go through `setHoveredBox` so they stay balanced.

## Sidebar

The day list collapses with the leftmost button in the header bar. SwiftUI's
built-in split-view toggle is removed (`.toolbar(removing: .sidebarToggle)`)
because it jumps to the detail column's edge once the sidebar is hidden; ours
stays on the left.

## Layout ratio

Drag the handle between the entry list and the composer to change the split.
The height is remembered across launches (`quicklog.composerHeight` in
`UserDefaults`).

Neither pane can collapse: the composer stays ≥110 pt and the entry list ≥120 pt,
clamped against the window's actual height — so the handle is always reachable,
and shrinking the window can't strand it off-screen.

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
- `just todos` — list open `- [ ]` lines
- `just nuke-data` — delete all entries (prompts)

## Markdown supported

Headers `#`/`##`/`###`, bullets `-`/`*`/`+` with 2-space nesting, checkboxes
`- [ ]`/`- [x]`, `**bold**`, `*italic*`, `` `code` ``. Preview toggle in the
composer renders as you type.

## Manual test pass

1. `just run` — panel appears centred, cursor in the composer.
2. Type `# Day\n- **thing** done`, toggle *Preview* — header + bullet render.
3. `⌘↩` — entry appears above with a `HH:mm` stamp, composer clears.
4. `just today` in another terminal — the markdown is on disk.
5. `esc` hides. `⌘⇧Space` from another app brings it back on top, focused.
6. Sidebar: today is labelled *Today*. Add `~/Library/Application Support/quicklog/2026-08-01.md`
   by hand, reopen the panel — that day is listed.
7. Click that old entry's text — the editor opens with the caret at the end and
   the keyboard already focused. Type, then `⌘↩`. `cat` the file: same file name,
   same `# 2026-08-01` title, same `## HH:mm` stamp, new body.
8. Click it again → `⌘A`, delete, `⌘↩` (button reads *Delete*). The row fades and
   collapses; other entries intact.
9. Click the undo arrow at the top — the deleted entry is back. Redo arrow —
   gone again. Both grey out when their stack is empty, and label themselves on
   hover.
10. Drag the handle above the composer to both extremes — it must track the
    cursor without vibrating, and neither pane may collapse. `just restart` — the
    split is remembered.
11. Drag across an entry's text to highlight it, then `⌘C` — must copy without
    entering edit mode.
12. Drag the panel to a corner, `just restart` — it reopens in the same spot.
13. Save an entry with two boxes — `- [ ] send email to X` and `- [ ] book the
    room`. Both render as empty boxes and `just todos` lists both. Click the
    first box — only it ticks, greys and strikes through, and the editor must
    *not* open. Click the text next to it — the editor opens. Undo arrow — the
    box goes back to unticked.
14. Click the leftmost header button — the day list collapses and the button
    stays on the left. Click again to bring it back.

## TODO

- Week/month grouping in the sidebar.
- Search.
- Configurable hotkey in-app (hardcoded to `⌘⇧Space` today).
- Draft is lost if the app quits before `⌘↩` — no draft persistence.
- Undo history is in-memory; quitting clears it.
- New entries always go to today; you can't back-date an entry to a past day.

## Tests

```sh
just test
```

`Tests/main.swift` — 29 checks over storage: that a user's own `##` headers
don't split an entry, that editing an old entry preserves its file name, title,
preamble and every other stamp, the file layout, blank edit = delete, the
file-removal rules, and per-line checkbox resolve/reopen.

It's a plain executable compiled against `StorageManager.swift`, not an XCTest
target: XCTest and swift-testing ship with Xcode, and this only needs Command
Line Tools. Exits non-zero on failure.

UI behaviour (panel, hotkey, caret, drag) isn't covered — see the manual pass
above.

## Layout

```
Package.swift
Justfile
Resources/Info.plist
Sources/quicklog/
  QuicklogApp.swift      # entry point, single-instance lock, hotkey, menu bar
  PanelController.swift  # floating NSPanel + root view
  EntryView.swift        # composer, entry list, inline editor, markdown renderer
  SidebarView.swift      # day list
  StorageManager.swift   # flat .md read/write/edit/delete + JournalStore + TaskLine
Tests/main.swift         # storage + checkbox tests (just test)
```

Sources live under `Sources/quicklog/` rather than the repo root — SwiftPM
requires it.
