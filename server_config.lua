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

    -- A multiblock Item Vault can appear once for every wired modem attached
    -- to it. Identical vault endpoints are treated as one storage so stock is
    -- not counted twice. Set false only if separate, identical vaults really
    -- are connected to the same bridge.
    deduplicateItemVaults = true,

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
