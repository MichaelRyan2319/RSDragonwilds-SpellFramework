# Spell Framework for RuneScape: Dragonwilds

A UE4SS Lua mod for RuneScape: Dragonwilds that adds custom spells to the game's
own spell system. Each spell is a small Lua file in the `Spells` folder. Custom
spells:

- are listed in the Spellbook (**P**) under **Custom Spells**;
- can be dragged into the spell radial (**Q**);
- are cast like the game's spells, with a cast animation, a rune cost and a
  cooldown.

A spell can have **variants**: casting it opens a second wheel where you pick
one. That keeps the Spellbook down to one entry per spell.

The framework has no spells of its own. Each spell is a separate mod that needs
the framework:

| Spell mod | What it does |
| --- | --- |
| [Accio](https://github.com/MichaelRyan2319/RSDragonwilds-AccioSpell) | Summon an item by name from nearby storage, or pull every item on the ground around you |

- Works in your own world (single player, or as the host).
- Your saves stay valid with or without the mod (see "Saves" below).
- Doesn't change any world settings, so achievements keep working.

Built for game build 26162923 (Unreal Engine 5.6) with UE4SS v3.0.1.

## Requirements

- [UE4SS for RuneScape: Dragonwilds](https://github.com/MichaelRyan2319/RSDragonwilds-UE4SS).
  Any other UE4SS v3 install works too.

## Install with Mod Loader

[Mod Loader](https://github.com/MichaelRyan2319/ModLoader) installs the mod and
keeps it up to date.

1. **Add game** and pick RuneScape: Dragonwilds. Mod Loader 1.0.1 or later sets
   the mods folder to the game's inner `RSDragonwilds` folder (the one with
   `Binaries` and `Content` in it). If you added the game with an older version,
   edit it and choose that folder.
2. **Add mod** `MichaelRyan2319/RSDragonwilds-SpellFramework`. The mod needs
   UE4SS, so Mod Loader 1.1.0 or later offers to add
   `MichaelRyan2319/RSDragonwilds-UE4SS` as well; click **Yes**. With an older
   Mod Loader, add `MichaelRyan2319/RSDragonwilds-UE4SS` yourself first.
3. Add the spell mods you want (e.g. `MichaelRyan2319/RSDragonwilds-AccioSpell`).
   Adding a spell mod first also works: Mod Loader 1.1.0 or later then offers to
   add the framework and UE4SS.
4. Start the game, load your world, press P and open **Custom Spells**.

## Install by hand

1. Install UE4SS (see Requirements).
2. Download `SpellFramework.zip` from the [Releases](../../releases) page.
   In Steam, right-click RuneScape: Dragonwilds > Manage > Browse local files,
   then open the `RSDragonwilds` folder (the one with `Binaries` and `Content`
   in it) and extract the zip there. The mod ends up in
   `Binaries\Win64\ue4ss\Mods\SpellFramework`.
3. Install the spell mods you want the same way. Their files go into
   `SpellFramework\Spells`.
4. Start the game and load your world.

The mod folder contains `enabled.txt`, so UE4SS loads it without any change to
`mods.txt`. To install from this repo instead of a release, copy the
`SpellFramework` folder into `Win64\ue4ss\Mods\`.

## Using it

1. Press **P** to open the Spellbook. Custom spells are in their own
   **Custom Spells** category.
2. Drag a spell into a slot of the spell radial, like any other spell.
3. Hold **Q**, pick the spell and cast it. A spell with variants opens a second
   wheel; pick a variant and the cast animation plays.

## Making your own spells

Copy `Spells\_Template.lua`, rename the copy (files starting with `_` are
ignored), edit it and restart the game. The template explains every field and
the helpers a spell can use: messages, the player's bag, nearby storage, items
on the ground, text prompts and wheels. The
[Accio mod](https://github.com/MichaelRyan2319/RSDragonwilds-AccioSpell)'s
`Accio.lua` is a complete example with variants and a text prompt.

A spell file sets an `id`, a `name`, a `description`, an `icon`, a `base` (the
game spell whose cast animation it uses), a rune `cost`, a `cooldown`, and an
`OnCast` function. A spell with variants lists them under `variants` instead.

To share a spell as its own mod, copy the Accio mod's layout:
- put the file at `SpellFramework/Spells/<Name>.lua` in the zip;
- add a `modloader.json` that requires this framework, so Mod Loader offers it.

If UE4SS can't list the folder, the log says so, and the framework loads only
the files named in `Spells\_list.txt` (one file name per line; create it
yourself).

## Settings

Edit `Win64\ue4ss\Mods\SpellFramework\Scripts\config.lua` in Notepad, then
restart the game.

| Setting | Default | What it does |
| --- | --- | --- |
| `CategoryName` | `"CUSTOM SPELLS"` | Name of the Spellbook category |
| `CategoryIcon` | `""` | Texture for that category; empty uses the Magic skill's icon |
| `DebugLogging` | `false` | More detail in the log |

## Saves

The game refuses to load a character whose save contains a spell it doesn't
know, so a custom spell is never saved under its own ID. It borrows the save ID
of Siphon Runes, a spell everyone has. The mod remembers which radial slot holds
which custom spell in its own file, `saved_slots_<character>.txt`, in the mod
folder.

If you remove the framework or a spell mod, those slots show Siphon Runes, and
your character loads normally.

## Achievements

The game skips achievement unlocks only in Creative and Custom worlds. This mod
never touches the world's mode or settings. The game's mod check (`CheckForMods`)
only logs a warning and marks the world as modded for people joining; it doesn't
block achievements.

## Troubleshooting

The log is `Win64\ue4ss\UE4SS.log`. Lines from this mod start with
`[SpellFramework]`, including errors in spell files. Set `DebugLogging = true`
in `config.lua` for more detail.

## Uninstall

Delete `Win64\ue4ss\Mods\SpellFramework`, or remove it in Mod Loader.

## Credits

UE4SS is made by the UE4SS team ([RE-UE4SS](https://github.com/UE4SS-RE/RE-UE4SS),
MIT licence).
