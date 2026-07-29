# starbattle.koplugin

A Star Battle puzzle plugin for [KOReader](https://github.com/koreader/koreader).

## Screenshot

*(Screenshot to be added.)*

## Rules

Place exactly N stars per row, column, and bold outlined region. No two stars may be adjacent — including diagonally adjacent. Tap a cell to cycle: star → empty marker → blank.

## Features

- **1-star and 2-star variants**
- **Multiple grid sizes** — 8×8, 10×10
- **Non-adjacency check** — highlights conflicting stars
- **Auto-save** — puzzle state saved and restored on next launch

## Installation

1. Download `starbattle.koplugin.zip` from the [latest release](../../releases/latest).
2. Extract into the `plugins/` folder of your KOReader data directory.
3. Restart KOReader.
4. Open the menu → **Tools** → **Star Battle**.

## Controls

| Action | How |
|--------|-----|
| Place star / mark empty / clear | Tap cell (cycles) |
| Check progress | Tap **Check** |
| New puzzle | Tap **New** |
| Show rules | Tap **Rules** |

## Known limitations

Generation now requires the region layout to have exactly one valid
star placement, verified by a bounded backtracking solver. In the rare
case where the retry budget is exhausted before a proven-unique layout
is found, generation falls back to the best structurally-valid layout
found (guaranteed to have at least one solution, just not proven to be
the only one).

## License

GPL-3.0 — see [LICENSE](LICENSE).
