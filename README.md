# RickQOL

A controller-friendly quality-of-life addon for **World of Warcraft: Forever** (Interface 16001).

## Features

- **Quest map pins**: world map and minimap pins for every quest you can pick up but haven't, including grey quests (a completionist view). Festival, world event and system quests stay hidden while their event isn't running.
- **Waypoints**: click a pin, or use the "nearest pending quest" key binding, to place Blizzard's map pin with the guide arrow.
- **Available quests window**: a list of the quests you can take in your current zone, navigable with the controller (D-pad, A to pin and track, B to close, Y to sort). It marks quests that start a chain. Open it with RB while the quest tracker has controller focus, with a key binding, or with `/rqol quests`.
- **Bags**: Blizzard's combined bag window rearranged into one row per bag with bag icons on the left. It keeps Blizzard's look and the native controller cursor, and turns on item comparison.
- **Junk**: grey items are sold automatically at vendors.
- **Threat bar**: a small threat bar in Blizzard's cast-bar style.

## Requirements

- QuestieDB (the Forever build) for the quest features (optional; the other features work without it).

## Install

Copy or symlink the `RickQOL` folder into `World of Warcraft/_forever_/Interface/AddOns/`.

## Commands

`/rqol` lists all commands.
