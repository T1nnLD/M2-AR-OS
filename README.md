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
scroll and click) and to the Hotkey module (`glasses_key_pressed`). With only a
Hotkey module, press once to open it and again to run the selected action.

Inside the Create Storage panel, use the wheel to select an item. Left click
takes one, right click takes a stack, middle click deposits the held item, and
`C` requests one crafted item. Closing the Keyboard module closes the panel.

## Create storage bridge

Use a second CC computer at the Create logistics network. It needs:

1. a Wireless/Ender Modem;
2. a wired connection to a Create Stock Ticker;
3. an Advanced Peripherals Inventory Manager with a Memory Card bound to the
   same player (required for transfer directly to/from the player);
4. an input inventory which feeds a Packager/Stock Link;
5. an output address and inventory where requested packages are unpacked.

Copy the `m2os` directory and `m2os_server.lua` to that computer, then edit
`m2os/server_config.lua`. The inventory names shown by `peripherals` must match
`inputInventory` and `outputInventory`. `outputAddress` must match the package
address configured on the Create network.

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

`craft` submits an order to Create just like the Stock Ticker. The Create
Factory Panel/Gauge recipes and package routes still have to be built in the
world. If an Inventory Manager or output buffer is omitted, the order is sent
but remains in the configured output inventory for manual pickup.

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
