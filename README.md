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

To install an exact revision, pass its commit hash after the role, for example
`wget run <installer-url> glasses <commit>`. The installer prints the source
revision and fetches every file from that commit. To avoid an older launcher
elsewhere on the shell path, run `/m2os.lua` or `/m2os.lua tracker` explicitly.

## Start

On the pocket computer inside the Smart Glasses:

```text
m2os
```

The first start creates `/m2os-state.cfg`. App switches selected through the
radial menu are remembered there.

THREAT BOXES supports living mobs of any mod, including passive and neutral mobs.
Players, armor stands, dead mobs and nonliving entities are excluded. The nearest
`tracker.maxTargets` eligible mobs are shown (five by default).
`tracker.aggressiveOnly = true` (the default) marks only mobs whose detector
data reports `aggressive = true`. Set it to `false` to mark all mobs: passive
mobs are green, neutral mobs yellow, and hostile or attacking mobs red. Vanilla
hostile types (including idle zombies) stay red before acquiring a target.
Neutral mobs
change yellow to red on aggression and back when calm; the whole frame and
beacon are recoloured without recreating them. Vanilla neutral types are built
in. Add modded neutral types with `tracker.neutralMobs = { ["modid:entity"] = true }`;
use `false` for a specific ID to override a built-in neutral type. The yellow
colour uses `theme.yellow` (default `0xFFD54A`, also used with older configs).
The obsolete `targetMode` setting is ignored. Basic scans do not expose mob
category or neutral disposition, so aggression and the neutral type list are
used together with a built-in vanilla hostile list for colouring. Add modded
hostiles with `tracker.hostileMobs = { ["modid:monster"] = true }`; otherwise an
unknown modded mob turns red when it reports aggression. A monster category is
also honoured when a provider supplies it.
AP 0.8.2a does not provide exact bounding-box dimensions; unknown mobs use an
estimate based on eye height. For unusual proportions, add an adult size to
`tracker.entitySizes`, for example `["modid:entity"] = { width = 2, height = 3 }`.
The tracker reads the detector's server configuration and limits scans to its
free radius and cooldown. Glasses cannot fuel scans beyond the free radius.
Scan failures are reported in a HUD notification and the computer console.
Scans use `detailed=false`: AP 0.8.2a still returns coordinates, health and eye
height, without decoding nearby players' inventories and extra entity data.
This avoids the detailed conversion path which can throw Java exceptions on
some modpacks. Repeated scan errors back off to at most one attempt per 30s.
Run `m2os tracker` with the HUD stopped to check the detector, saved enabled
state, server limits and whether zombies are detected within eight blocks.

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
ten or `Shift` for a stack. Item variants with different NBT are listed
separately, and the selected variant is withdrawn from its exact inventory slot
instead of matching only its registry name.

The bridge stores compact indexed metadata in `/m2os/item_detail_cache.db`.
Bridge protocol v10 starts in safe mode and never calls `getItemDetail`
automatically. It only uses the lightweight data returned by `list()` plus any
metadata already present in the persistent cache. This avoids a Java-side
peripheral failure taking down the dedicated server.

Detailed names and enchantment tooltips can be enabled explicitly with
`enableItemDetails = true`, but this is unsafe on modpacks where a detailed
inventory read has already crashed the server. When enabled, the bridge waits
ten seconds after launch and indexes one unique variant every two seconds.
Before every such call it writes a tiny
`/m2os/item_detail_inflight.db` journal. If Minecraft disappears during that
exact call, the next run safely skips the suspect detail instead of repeating a
server crash loop; the bridge screen reports it under `Safety:` and the item is
still usable by registry ID. Every successful variant is committed to the cache
before indexing continues, so a restart resumes from durable progress.

For localized item and enchantment names, install **CC: Tweaked Unicode
Support** on both the Minecraft client and server. In safe mode M2OS uses cached
display names and its offline Russian fallback for Minecraft, Create and
Advanced Peripherals. English search remains available through registry names,
cached English aliases and `@mod` names.
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

## Automatic player inventory restocking

Update both the glasses and storage bridge. Use the existing Inventory Manager
with the player's bound Memory Card and the same named wired storage network
as ordinary withdrawals. No additional peripheral is required.

In the storage panel, hover an item and press **K** while the search field is
inactive. Enter the minimum quantity and click **Сохранить**. The Inventory tab
also accepts K for its selected item. For example, with a target of 64 bread and
50 in the player's inventory, the bridge adds only 14. Quantity +/- buttons
use Ctrl for ten and Shift for 64; clicking the number enables direct typing.
The radial action **АВТОПОПОЛНЕНИЕ** opens saved rules so they can be edited,
disabled, enabled or deleted. Esc closes the panel.

Rules count the total quantity by item registry ID, including all variants of
that ID. They maintain a minimum, never remove surplus and do not craft missing
stock. Disable a rule before deliberately depositing all of that item, otherwise
it will be supplied again. Each rule belongs to the UUID on the Manager's Memory
Card; another card owner is never intentionally supplied by that rule.

The bridge saves rules in `/m2os/restock.cfg` and runs them while the glasses
panel is closed, even with the HUD stopped. The bridge and its storage chunks
must remain loaded and the player must be online. On startup, saved rules wait
ten seconds before checking. Normal checks are spaced by at least five seconds
per rule and delivery is capped at 64 per cycle. Large networks are checked in
paced slices. Empty stock, missing storage, offline owners, transfer errors and
a full inventory are reported in the rule status; failed transfers back off
for 30 seconds. Live quantities and ownership are checked again before import,
so an intervening manual delivery reduces the automatic deficit.

Optional bridge settings are `restockFile`, `restockIntervalMs` (minimum 2000)
and `restockStartDelayMs`. Preserved old configs automatically use the defaults.
Discovery and counting use basic inventory APIs; this feature does not enable
full item metadata indexing or Create package requests.

## Find and highlight blocks in the world

Install a **Geo Scanner** in the player's Smart Glasses, together with the
Overlay and Keyboard modules. Only the glasses need this update; the storage
bridge is not involved. Select **ПОИСК БЛОКОВ** in the radial menu, type a block
registry ID and press Enter or **Искать / обновить**:

- `minecraft:diamond_ore` (or simply `diamond_ore`)
- `create:item_vault`
- `#c:ores/diamond` to match a block tag, including multiple ore variants

Delete clears the field; Backspace edits it and paste is supported. The field
expects registry IDs/tags, not localized item names. Radius +/- controls request
1–16 blocks. The app reads the Geo Scanner's server configuration and caps the
request to its free radius and maximum radius, respecting its cooldown. Glasses
cannot pay for a scan beyond their free radius. The panel displays the actual
radius, unique matches, displayed matches, and nearest block coordinates.

Matches get gold wireframe boxes through walls. Closing the panel with Esc
returns to play and leaves scanning/highlighting active. Open the panel and
press **Остановить** to clear it. Periodic scans remove markers for mined or
changed blocks. The default interval is five seconds; the nearest 24 matches
are drawn to bound overlay load. With AP 0.8.2a the scan offsets point from the
wearer's eye to block centers. Results are snapped to the block grid; a scan
made while the player moves too far during the native call is discarded until
a more accurate scan is possible. Unexpected native errors stop automatic
scanning; cooldown errors wait for the next attempt.

Settings are under `blockSearch` in the glasses config (`range`, `intervalMs`,
`maxMarkers`, `stateFile`); preserved older configs use defaults automatically.
The last valid query and requested radius are saved in `/m2os/block_search.cfg`.
A HUD restart restores those fields with scanning off until explicitly started.
This app loads on existing configs without editing their `modules` list.

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
