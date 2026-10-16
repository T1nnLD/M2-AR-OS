-- Create storage bridge configuration.
-- Peripheral names can be found with: peripherals
return {
    protocol = "m2os.storage.v1",
    sharedKey = "m2os", -- change this on both the client and server

    -- Every wired peripheral with list() and size() is treated as storage.
    -- Add machine buffers or private inventories here to ignore them.
    inventoryBlacklist = {
        -- "minecraft:furnace_0"
    },

    -- The Inventory Manager and every storage must have stable wired-network
    -- names and be connected to the same cable network. Local aliases
    -- (left/right/front/...) are ignored because the Manager cannot address
    -- them reliably from another peripheral connection.
    requireNamedInventories = true,

    -- A multiblock Item Vault can appear once for every wired modem attached
    -- to it. Identical vault endpoints are treated as one storage so stock is
    -- not counted twice. Set false only if separate, identical vaults really
    -- are connected to the same bridge.
    deduplicateItemVaults = true,

    -- Detailed NBT/enchantment reads are deliberately throttled because too
    -- many getItemDetail calls in one request can trip a server watchdog.
    -- Keep this at 4 (8 is the hard safety limit).
    itemDetailCallsPerScan = 4,

    -- Optional registry-name fragments for unusual modded enchantable items.
    -- Example: "modid:laser_tool". Vanilla tools and common modded tool names
    -- are detected automatically.
    detailedItemPatterns = {},

    -- Direct inventory transfers are the default and do not use Create
    -- packages. Crafting through the Stock Ticker remains opt-in because it
    -- requires a complete, stable package route.
    enableCreateCrafting = false,

    -- The settings below are only used when enableCreateCrafting is true.
    -- Address printed on the Packager connected to the player's output chest.
    outputAddress = "M2OS_OUT",

    -- Packages requested from the Stock Ticker must be unpacked here.
    outputInventory = "minecraft:chest_0",

    transactionTimeout = 45,
    trustedIds = {}, -- empty means every computer with the shared key

    -- Optional detailed context providers. Key format: dimension:x:y:z
    -- Value is the wired peripheral name of an inventory or Block Reader.
    machines = {
        -- ["minecraft:overworld:10:64:-20"] = "blockReader_0"
    }
}
