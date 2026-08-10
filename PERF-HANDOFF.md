# Handoff: runaway CPU / freeze when scrolling a past day — FIXED

## Outcome

`LazyVStack` → `VStack` in `entryList` (`EntryView.swift`). Verified by owner:
smooth, 0% CPU hands-off, 36M steady. Previously ~100% of a core, memory to 388M.

Also kept: `entriesHeight(available:)` gives the entry list and the past-day footer
definite heights, replacing `.frame(maxHeight: .infinity)`. This is **not** the fix
— the spin survived it — but it removes real measurement work. See its doc comment.

## Real mechanism

Lazy placement measures each row against the visible rect; the `ScrollView` sizes
its content from those rows. Once content overflows *and is scrolled*, the two feed
each other and never reach a fixed point. Hot frames: `LazySubviewPlacements.updateValue`
(372), `placeSubviews` (355), `LazyVStackLayout.sizeThatFits` (221),
`ScrollViewLayoutComputer.Engine.sizeThatFits` (228).

Not "past days" as such — **enough content to overflow**. Past days held ~8× today's
text (1201 bytes vs 143). A short day looks fine on any build.

## Corrections to the original handoff

Its mechanism section and candidate ranking were both wrong. Each disproved by
sample + the hands-off persistence check:

- **`.textSelection(.enabled)` / `SelectionOverlay` — not the cause.** Removed
  entirely; still stuck at ~100%. It appears in samples (212) because it is a
  participant in the layout pass, not the driver. Feature retained.
- **Editor height (`minHeight`/`maxHeight`) — wrong target.** The repro has no
  editor open; `inlineEditor` is not in the tree while scrolling.
- **Both `.onHover` modifiers — not the driver.** Removed row *and* per-checkbox
  hover; still stuck at 100% / 288M. `enqueueHoverUpdateIfNeeded` was the single
  largest frame (314) and still only a passenger — largest ≠ causal.
- **`.animation(value:)` modifiers — not the driver.** Animation frames peaked at
  6 samples. Both restored.
- **Definite heights — real but insufficient.** Cut `_FlexFrameLayout.sizeThatFits`
  from 334 to 15 samples; freeze unchanged.
- **Markdown files — fine.** Not malformed; ids are unique (`time#occurrence`).
  Only content *volume* mattered.

## Method notes — the part that actually mattered

- **Distinguish stuck from transient.** A 65% reading during scrolling means
  nothing; scrolling costs CPU. The symptom is that it *stays* pegged after you
  stop touching it. An early `.textSelection` result was misread as exoneration
  for want of this check, and had to be redone.
- **Measure untouched.** An idle launch reads 0% on every build, fixed or not. Any
  measurement taken while someone is using the window is not a baseline.
- **Largest frame ≠ cause.** Hover dominated the profile and was irrelevant.
- Tests cannot reach this. It needs a GUI repro plus `sample`.

## Repro (for regressions)

1. `just restart`
2. Click a day with enough entries to overflow the list (e.g. 2026-08-07).
3. Scroll up/down.
4. Stop touching it, then `top -pid $(pgrep -x quicklog) -l 4 -stats pid,cpu,mem`.
   Pegged and staying pegged = regressed.

`/tmp/ql-watch.sh` polls CPU and auto-fires `sample` at 50%. Useful, but its firing
only flags a spike — always follow with the hands-off check above.

## Still open

- **Hover cost, ~10–19% while hovering entries.** Separate, non-blocking.
  `enqueueHoverUpdateIfNeeded` re-enqueues a full-tree hit test, driven by one
  `.onHover` per row (`EntryView.swift`) plus one per checkbox
  (`MarkdownText.swift:39`). Fix would collapse to one `.onHover` per row and
  derive the checkbox from local coordinates. Confirmed *not* related to the freeze.

## Build / test

- `just build`, `just test`, `just restart`
- Tests are a plain executable, not XCTest. `Justfile` compiles an explicit file
  list — any new source file must be added there or tests won't link.
- 91 checks pass.

## Out of scope

- `PLAN.md` still references the deleted `StorageManager.swift`. Historical doc.
- The `## HH:mm`-in-body entry split is intended, pinned by
  `testExactHeaderInBodySplitsEntry`. Do not "fix" it.
