# M2OS 0.1

M2OS is a modular HUD for CC:Tweaked and Advanced Peripherals 0.8.2a. It does
not modify or start `d.lua`.

## One-command install

On the Smart Glasses computer:

```text
wget run https://raw.githubusercontent.com/T1nnLD/M2-AR-OS/master/install.lua glasses
```

On the computer connected to the Create storage network:

```text
wget run https://raw.githubusercontent.com/T1nnLD/M2-AR-OS/master/install.lua server
```

Use `all` instead of `glasses` or `server` to install both roles. Running the
same command again updates the code. Existing `m2os/config.lua` and
`m2os/server_config.lua` are preserved; replaced program files receive a `.bak`
backup.

## Start

On the pocket computer inside the Smart Glasses:

```text
m2os
```

The first start creates `/m2os-state.cfg`. App switches selected through the
radial menu are remembered there.

The radial menu reacts to the Keyboard module (`keyboard_open`, mouse movement,
scroll and click) and to the Hotkey module (`glasses_key_pressed`). It stays open
until an action is selected or the screen is closed; it has no idle timeout.

With only a Hotkey module, a short press opens the menu, later short presses move
to the next action, and a press held for at least 0.6 seconds runs it. This mode
never takes player control. When both modules are installed they share the same
Minecraft key; M2OS ignores the duplicate Hotkey event and lets the Keyboard
module provide mouse selection.

Advanced Peripherals 0.8.2a does not expose a Lua method for closing its Keyboard
Screen. Consequently, after choosing a normal toggle with the mouse, press
`Esc` once to return to the game. M2OS shows this instruction instead of leaving
an invisible input screen. Interactive actions such as Create Storage keep input
until their window closes.

The Create Storage panel is a paged grid rendered with Advanced Peripherals'
native `Item` overlay objects. Icons come directly from Minecraft, including
modded items and active resource packs, so no texture download is needed. Move
the mouse to select an item; the wheel changes whole pages, and the scrollbar
can also be clicked. Click the search field or press `F` to search in Russian,
English, or by registry ID. Prefix a mod with `@` (`@create`, or
`@create шестерня`) to limit results to that mod. Search is case-insensitive for
both Cyrillic and Latin text. `Backspace` removes one complete UTF-8 character,
`Delete` clears the query, and `Enter` applies it immediately (otherwise it
applies after a short delay). Left click adds one item to the request queue,
`Ctrl` + left click adds ten, and `Shift` + left click adds a stack. Right click
also adds a stack.
Select the `INVENTORY` tab at the top, or press `I`,
to see the player's inventory. Clicking an occupied player slot deposits that
slot's complete stack; depositing a single item is intentionally not supported.
The clicked stack is reserved in the queue. Press the purple `ПУСК` button
or `Enter` to perform every queued transfer. A partial transfer reports that
storage is full and shows the moved/total count; withdrawal behaves the same way
when the player inventory has insufficient space. Middle click or `P` queues up
to 64 items matching the main-hand item. `C` queues one crafted item when
optional Create crafting is enabled; the same `Ctrl`/`Shift` amount modifiers
apply to `C`. Closing the Keyboard module closes the panel.

The request bar at the bottom mirrors Create's Stock Keeper and shows native
item icons, editable amounts and their current state. Clicking an entry removes
it before delivery. Successfully completed transfers are removed automatically;
failed or partial transfers remain visible for retry. Scroll up/down over an
entry to add/subtract one; hold `Ctrl` for
ten or `Shift` for a stack. Enchanted and plain items are listed separately.
Enchanted cells carry a `З` badge, and hovering
them opens a tooltip with their enchantments. Bridge protocol v8 takes one
inventory snapshot, then indexes each unique item variant once with a pause
between `getItemDetail` calls. Identical stacks share one compact cache entry,
and progress checks no longer rescan a large Create vault. A temporary `?` badge
means that the item is still being indexed. The
selected variant is withdrawn from its exact inventory slot instead of matching
only its registry name.

The bridge stores compact indexed metadata in `/m2os/item_detail_cache.db`.
It waits ten seconds after launch, then indexes one unique variant every two
seconds, so nobody has to keep the storage window open and a server which has
just restarted is not hit by a burst of peripheral calls.
The cache survives bridge and server restarts, is shared by identical item
variants across all inventory slots, and is revalidated after seven days by
default. Configure or disable it with `itemDetailCacheFile` and
`itemDetailCacheMaxAge` in `server_config.lua`.

Before every `getItemDetail` call the bridge writes a tiny
`/m2os/item_detail_inflight.db` journal. If Minecraft disappears during that
exact call, the next run safely skips the suspect detail instead of repeating a
server crash loop; the bridge screen reports it under `Safety:` and the item is
still usable by registry ID. Every successful variant is committed to the cache
before indexing continues, so a restart resumes from durable progress.

For localized item and enchantment names, install **CC: Tweaked Unicode
Support** on both the Minecraft client and server. The bridge indexes the real
display names of items which are currently in storage, in the same safe
background batches used for enchantments. M2OS only ships an offline Russian
fallback for Minecraft, Create and Advanced Peripherals; it no longer stores a
multi-megabyte dictionary for every item in the modpack. English search remains
available through registry names, cached English aliases and `@mod` names.
Without the Unicode addon, names which have already degraded to `????` are
shown using their readable registry IDs instead.

## Create storage bridge

Use a second CC computer at the warehouse. It needs:

1. a Wireless/Ender Modem;
2. one common wired modem network connected to both the Inventory Manager and
   all storage inventories;
3. an Advanced Peripherals Inventory Manager with a Memory Card bound to the
   same player (required for transfer directly to/from the player);
4. activated wired modems on the Inventory Manager and on the chests, barrels,
   Item Vaults or other inventories that should be included.

Copy the `m2os` directory and `m2os_server.lua` to that computer, then edit
`m2os/server_config.lua`. The bridge automatically discovers every accessible
peripheral which exposes both `list()` and `size()`. The Inventory Manager is
excluded automatically. Add unrelated machine buffers to `inventoryBlacklist`:

```lua
inventoryBlacklist = {
    "minecraft:furnace_0",
    "create:depot_0"
}
```

Stock listing, withdrawal and deposit operate directly on these wired
inventories. They do not use the Stock Ticker, Packagers, package addresses or
an intermediate output chest.

Storage must have a stable wired-network peripheral name such as
`create:item_vault_0`, not a local side alias such as `left` or `right`. Attach
an activated wired modem directly to the storage and connect it by networking
cable to the bridge computer. Do the same for the Inventory Manager and join
both modems with that exact same cable network. Merely attaching the Manager to
the side of the computer is not sufficient: Advanced Peripherals resolves a
transfer target only inside the wired network through which the Manager itself
is connected. Side aliases are ignored by default because Inventory Manager
cannot reliably address them for player transfers. The bridge checks every
target with a zero-item transfer, reports `usable / found` on its status screen,
and rejects cross-network storage with a clear message instead of attempting a
real transfer. This guard is controlled by `requireNamedInventories` in
`server_config.lua`.

Create Item Vaults are detected explicitly. Attach and activate a wired modem
on any block of each assembled Vault; Create forwards that connection to the
multiblock controller and M2OS sees its combined inventory. If several wired
modems expose the same assembled multiblock, CC:Tweaked reports several
peripheral names, but the bridge ignores identical duplicate endpoints and
prints an `Aliases:` line. The bridge reports the logical result as
`Storage: N inventories (V vaults)`. This is controlled by
`deduplicateItemVaults` in `server_config.lua`.

Start it with:

```text
m2os_server
```

The installer does not modify startup files. To launch the bridge automatically,
put `shell.run("m2os_server")` in your own `/startup.lua`. CC:Tweaked computers
cannot execute while their Minecraft chunk is unloaded. Force-load the chunks
containing the bridge computer, Inventory Manager and storage (for example with
the modpack's chunk-loading system), otherwise indexing pauses until a player
loads them again.

Useful commands from the glasses computer:

```text
m2ctl stock iron
m2ctl take minecraft:iron_ingot 32
m2ctl put minecraft:cobblestone 64
m2ctl craft minecraft:precision_mechanism 4
```

`craft` is disabled by default. It can be enabled with
`enableCreateCrafting = true`, but still requires a Stock Ticker, a complete
Create package route, `outputAddress` and `outputInventory`. Ordinary `stock`,
`take` and `put` commands remain direct regardless of this option.

## Context details

The Context Inspector shows the block data included with a
`player_interaction` event. For detailed storage/furnace data, connect that
machine (or an AP Block Reader facing it) to the bridge computer and add its
coordinate to `machines` in `m2os/server_config.lua`:

```lua
machines = {
    ["minecraft:overworld:10:64:-20"] = "blockReader_0"
}
```

Generic inventories report occupied/total slots. A Block Reader reports furnace
progress when its block data exposes cooking fields. This explicit mapping is
needed because the pocket Geo Scanner and Keyboard target event do not expose
arbitrary block-entity NBT.

## Files

- `m2os.lua` — glasses launcher
- `m2os/kernel.lua` — lifecycle, scheduler, overlay ownership and services
- `m2os/api.lua` — app registration API
- `m2os/apps/` — desktop, tracker, storage, context and radial menu
- `m2os_server.lua` — Create bridge launcher
- `m2ctl.lua` — storage CLI
- `m2os/API.md` — extension API
