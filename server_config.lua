-- Create storage bridge configuration.
-- Peripheral names can be found with: peripherals
return {
    protocol = "m2os.storage.v1",
    sharedKey = "m2os", -- change this on both the client and server

    -- Address printed on the Packager connected to the player's output chest.
    outputAddress = "M2OS_OUT",

    -- Inventories adjacent/networked to the Inventory Manager computer.
    -- Packages requested from the Stock Ticker must be unpacked into outputInventory.
    outputInventory = "minecraft:chest_0",
    inputInventory = "minecraft:chest_1",

    transactionTimeout = 45,
    trustedIds = {}, -- empty means every computer with the shared key

    -- Optional detailed context providers. Key format: dimension:x:y:z
    -- Value is the wired peripheral name of an inventory or Block Reader.
    machines = {
        -- ["minecraft:overworld:10:64:-20"] = "blockReader_0"
    }
}
