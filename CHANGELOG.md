# Changelog

All notable changes to this project will be documented in this file.

## [1.6.1] - 2026-11-04

### Fixed
- A game no longer crashes when an outdated plugin is installed alongside:
  shared modules left behind by an older plugin are replaced by this
  plugin's own copy instead of being used as they are.

## [1.6.0] - 2026-11-04

### Changed
- 10×10 puzzles build two to three times faster: from up to 0.35 s on a
  desktop (about 9 s on a Kobo) to about 0.1 s (about 2.5 s on a Kobo),
  0.02 s on average. The solution check skips placements it has already
  found to lead nowhere, also from one adjusted layout to the next, and
  runs as a plain loop. Same puzzles as before at every size.
- Uses less memory: the game loads when you open it, not when KOReader
  starts, so it no longer takes memory or startup time while unplayed.

## [1.5.0] - 2026-11-04

### Changed
- Much faster 10×10 puzzles: up to 7 s on a desktop (about 3 minutes on a
  Kobo) down to under 0.1 s (about 2 s on a Kobo). The solution check now
  places a whole row at a time and drops a row as soon as some column or
  region can no longer get its stars; a 10×10 layout with several
  solutions has a few cells moved to a neighbouring region until only one
  is left, instead of being thrown away. 6×6 and 8×8 puzzles are unchanged;
  10×10 ones are new layouts, and every one of them now has exactly one
  solution (about 1 in 10 used not to be proven).
- Opening the game no longer builds a puzzle it then throws away (it was
  generated even when a saved game was about to be restored).
- A "Generating puzzle…" progress bar shows when a puzzle takes more than a
  moment. Needs game-common 1.12.0.

## [1.4.3] - 2026-11-03

### Changed
- Picks up game-common 1.11.0: the shared on-screen keyboard (where used)
  gives every key the same letter size, and the no-repeat history helper.

## [1.4.2] - 2026-11-02

### Changed
- Picks up game-common 1.10.0: the shared Tools → Games menu also lists
  the games' new "· multiplayer" entries under Party & quiz.

## [1.4.1] - 2026-11-02

### Changed
- Listed under **Tools → Games**, grouped by category, instead of its own
  entry in the Tools menu (game-common 1.9.1).

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
