# Changelog

All notable changes to this project will be documented in this file.

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
