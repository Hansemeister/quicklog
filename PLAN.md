# quicklog — macOS journaling overlay app

## Goal
A lightweight macOS app for frictionless stream-of-consciousness writing throughout the day.

## Core features (POC)
- Global hotkey opens a floating `NSPanel` overlay (always on top of other windows)
- Text input with basic markdown rendering: bold, italic, headers, bullet lists, indentation
- Each entry is timestamped and appended to a flat markdown file per day (`YYYY-MM-DD.md`)
- Sidebar listing past entries grouped by day (week/month grouping post-POC)
- Storage: `~/Library/Application Support/quicklog/`

## Stack
- SwiftUI (native macOS)
- Flat `.md` files, one per day
- No sync, no backend — local only for now

## Out of scope (POC)
- Sync between machines
- Search
- Export
- Week/month grouping in sidebar

## File structure
```
quicklog/
  QuicklogApp.swift        # App entry, global hotkey registration
  PanelController.swift    # NSPanel setup (floating, always-on-top)
  EntryView.swift          # Text input + markdown rendering
  SidebarView.swift        # Day-grouped entry list
  StorageManager.swift     # Read/write flat .md files
```
