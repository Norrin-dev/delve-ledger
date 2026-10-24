# Delve Ledger

A small World of Warcraft (retail, Midnight) addon that shows your Delve progress as plain on-screen text, so you don't have to mouse over buffs and tooltips.

## Features

**In any Delve**
- **Boons**: lists the stats granted by the *Boons* buff (e.g. `Haste: 23%`), read from the buff's tooltip.

**In The Labyrinth of Kindo'jan only**
- **Chambers Completed: x/9** at the top.
- **Hexmasks**: Fiery, Thundering and Frozen Hexmask, red until acquired, green once you have the familiar.
- **Treasure Room**: reward counts (Bountiful Coffers, Bountiful Heavy Trunks, Mislaid Treasures, Small Trunks). Counts with a known maximum show as `x/max`: red at 0, yellow in progress, green when maxed.

The frame is hidden outside Delves.

## Commands

| Command | Effect |
|---|---|
| `/dl unlock` | Show the frame and make it draggable |
| `/dl lock` | Lock it in place (click-through) |
| `/dl reset` | Reset position |
| `/dl test` | Toggle showing the frame outside Delves |
| `/dl debug` | Print instance info and the raw Treasure Room tooltip |

`/delveledger` works as an alias in case `/dl` conflicts with another addon.

## Known limitations

- Values don't update during combat (the game hides buff/tooltip data from addons in combat); they refresh when combat ends.
- Treasure Room formatting (maximums, ordering, hidden lines) matches English tooltip text. Other client languages fall back to plainer output.
- Spell IDs may change with new seasons; they are defined at the top of `DelveLedger.lua`.

## Installation

Copy the `DelveLedger` folder into `World of Warcraft/_retail_/Interface/AddOns/`.
