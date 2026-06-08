# Star Battle

> **Status: stub — not yet implemented**

## Description

Place a fixed number of stars in each row, column, and region, with no two stars adjacent (including diagonals).

## Files to create

- `board.lua` — game logic, puzzle generator, serialize/load
- `board_widget.lua` — grid rendering and tap gestures
- `screen.lua` — full-screen layout (buttons + board)
- `main.lua` — PluginBase entry point

## Notes

Number placement puzzle — use GridWidgetBase from game-common.
