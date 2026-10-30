# Changelog

All notable changes to this project will be documented in this file.

## [1.4.0] - 2026-10-30

### Added
- "Daily Challenge" in the menu, right after "New game": today's puzzle at
  your size and difficulty, the same grid for everyone playing it today.
  Needs game-common 1.7.0.

## [1.3.0] - 2026-10-30

### Changed
- Redesigned play screen: the board is larger, filling the room the controls
  leave, with a full-width action bar under the status line and a single
  frame around the board.
- Stars are drawn as a real ★ sized to the cell (an "*" stood in for it: a
  small glyph that sat near the top), and empty marks as a disc instead of a
  tiny ".".
- The status line reads "8×8 · 1★/row · Stars: 3/8" and wraps in landscape
  instead of being cut off.
- Once the puzzle is solved (or revealed), the action bar shows "New game" in
  place of Undo/Hint/Reveal, so the next round no longer needs the menu.

### Fixed
- The grid's right and bottom border lines were drawn past the board's edge.
- Using a hint wiped the saved game; it is now kept. When a hint places the
  last star, the status shows the win message.

## [1.2.2] - 2026-10-07

### Fixed
- The Tools menu entry is translated again. `main.lua` took `_` from
  KOReader's `gettext`, which knows nothing of this plugin's strings, so the
  menu label stayed English while the game's own screen, which goes through
  `i18n`, was translated. `_` now comes from `i18n` here too.


## [1.2.1] - 2026-10-01

### Fixed
- Picks up game-common v1.5.0. Play statistics were recorded under a key no
  tool could match: `ReaderUI`/`FileManager:registerModule()` rewrite a plugin
  instance's `name` to `reader<id>` / `filemanager<id>` right after it is
  built, so this game's sessions were split across two rows and neither
  carried its plugin id. Rows written under the old keys are merged back on
  first read. The same release brings the `stopPlugin()` /
  `deletePluginSettings()` hooks KOReader 2026.07 calls when a plugin is
  deleted from the device (PR #15240).

  No change to this plugin's own code -- it inherits all of it from the
  shared library.

## [1.2.0] - 2026-09-30

### Added
- **Hint** button. Two taps, not one: the first says which cell is about to
  give, the second acts on it -- a player who is told where to look usually
  finds the rest themselves, and only pays for the full reveal if they want
  it. A cell that contradicts the solution is always reported before a fresh
  one is revealed, and on a mistake the hint empties the cell rather than
  solving it.

## [1.1.13] - 2026-07-31

### Fixed
- `board_widget.lua` referenced Blitbuffer color constants that don't
  exist (COLOR_GRAY_A), which evaluated to `nil` and crashed the
  color-comparison in `paintTo()` as soon as the corresponding
  highlight was drawn. Now uses the correct constant name(s)
  (COLOR_GRAY).

## [1.1.9] - 2026-07-29

### Fixed
- Generation accepted the first region layout for which *any* valid
  star placement existed, without checking for a second, different
  valid placement — measured only ~7% of accepted layouts were
  actually unique at some size/star-count combinations. Reworked the
  solver to count solutions (capped at 2) so generation can require
  uniqueness, falling back to the best structurally-valid layout found
  if the retry budget runs out (see README).
