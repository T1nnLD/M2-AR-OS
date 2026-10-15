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
the mouse or use the wheel to select an item. Left click takes one, right click
takes a stack, middle click deposits the held item, and `C` requests one crafted
item when optional Create crafting is enabled. Closing the Keyboard module
closes the panel.

## Create storage bridge

Use a second CC computer at the warehouse. It needs:

1. a Wireless/Ender Modem;
2. a wired modem network connected to the storage inventories;
3. an Advanced Peripherals Inventory Manager with a Memory Card bound to the
   same player (required for transfer directly to/from the player);
4. wired modems on the chests, barrels, Item Vaults or other inventories that
   should be included.

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
cable to the bridge computer. Side aliases are ignored by default because
Inventory Manager cannot reliably address them for player transfers. The
bridge reports ignored local inventories on its status screen. This guard is
controlled by `requireNamedInventories` in `server_config.lua`.

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
