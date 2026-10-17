local util = require("m2os.lib.util")
local i18n = require("m2os.lib.i18n")

local Server = {}

-- getItemDetail is a synchronous main-thread peripheral call. Calling it for
-- dozens of one-count items in a large Create vault can trip the dedicated
-- server watchdog, so detailed metadata is indexed in small bounded batches.
local ITEM_DETAIL_CALLS_PER_SCAN = 4
-- v2 also indexes display names for ordinary (non-enchanted) items. Discard
-- older entries so names captured before Unicode Support was installed do not
-- remain as question marks for the cache lifetime.
local ITEM_DETAIL_CACHE_VERSION = 2
local ITEM_DETAIL_CACHE_FILE = "/m2os/item_detail_cache.db"
local ITEM_DETAIL_CACHE_MAX_AGE_SECONDS = 7 * 24 * 60 * 60
local ITEM_DETAIL_CACHE_SAVE_DELAY_MS = 1000
local BACKGROUND_INDEX_INTERVAL_MS = 500

local LOCAL_SIDES = {
    left = true, right = true, top = true, bottom = true,
    front = true, back = true
}

local function trusted(config, sender)
    if not config.trustedIds or #config.trustedIds == 0 then return true end
    for _, id in ipairs(config.trustedIds) do
        if id == sender then return true end
    end
    return false
end

local function normalizeStock(raw, query, limit)
    local items = {}
    for key, value in pairs(type(raw) == "table" and raw or {}) do
        local item
        if type(value) == "table" then
            item = {
                name = value.name or (type(value.item) == "table" and value.item.name) or
                    (type(key) == "string" and key or nil),
                displayName = value.displayName or value.label,
                count = tonumber(value.count or value.amount or value.total) or 0,
                craftable = value.craftable == true or value.isCraftable == true,
                variant = value.variant,
                enchantments = value.enchantments,
                enchanted = value.enchanted == true,
                detailPending = value.detailPending == true
            }
        elseif type(key) == "string" then
            item = { name = key, count = tonumber(value) or 0 }
        end
        if item and item.name then
            item = i18n.localizeItem(item)
            if i18n.matchesItem(item, query) then items[#items + 1] = item end
        end
    end
    table.sort(items, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        if a.name ~= b.name then return a.name < b.name end
        return tostring(a.variant or "") < tostring(b.variant or "")
    end)
    while #items > (limit or 256) do table.remove(items) end
    return items
end

local function locateTicker()
    return util.findPeripheral({ "stock", "requestFiltered" },
        { "Create_StockTicker", "create:stock_ticker", "stockTicker" })
end

local function locateManager()
    local sideManager, sideName
    for _, name in ipairs(peripheral.getNames()) do
        local wrapped = peripheral.wrap(name)
        if wrapped and type(wrapped.importItem) == "function"
                and type(wrapped.exportItem) == "function" then
            -- Prefer the stable name supplied by a wired modem. A manager
            -- mounted directly on a computer side is still accepted, but it
            -- cannot normally see inventories living on another modem
            -- attachment/network.
            if not LOCAL_SIDES[name] then return wrapped, name end
            sideManager, sideName = wrapped, name
        end
    end
    return sideManager, sideName
end

local function isExcluded(config, name)
    for _, excluded in ipairs(config.inventoryBlacklist or {}) do
        if excluded == name then return true end
    end
    return false
end

local function peripheralTypes(name)
    local types = {}
    if type(peripheral.getType) ~= "function" then return types end
    local values = { peripheral.getType(name) }
    for _, value in ipairs(values) do
        if type(value) == "string" then
            types[value:lower()] = true
        elseif type(value) == "table" then
            for _, child in pairs(value) do
                if type(child) == "string" then types[child:lower()] = true end
            end
        end
    end
    return types
end

local function isItemVault(name, types)
    local lowerName = tostring(name):lower()
    if lowerName:find("item_vault", 1, true)
            or lowerName:find("itemvault", 1, true) then return true end
    for kind in pairs(types) do
        if kind:find("item_vault", 1, true)
                or kind:find("itemvault", 1, true) then return true end
    end
    return false
end

local function vaultSnapshot(inventory)
    local okSize, size = pcall(inventory.size)
    local okList, slots = pcall(inventory.list)
    if not okSize or not okList or type(slots) ~= "table" then return nil end
    local parts = { tostring(size) }
    local indexes = {}
    for slot in pairs(slots) do indexes[#indexes + 1] = slot end
    table.sort(indexes, function(a, b) return tonumber(a) < tonumber(b) end)
    for _, slot in ipairs(indexes) do
        local stack = slots[slot]
        if type(stack) == "table" then
            parts[#parts + 1] = table.concat({
                tostring(slot), tostring(stack.name or ""),
                tostring(stack.count or 0), tostring(stack.nbt or "")
            }, ":")
        end
    end
    return table.concat(parts, "|")
end

local function locateInventories(config)
    local inventories = {}
    local vaultSnapshots = {}
    local duplicateEndpoints = 0
    local ignoredLocalInventories = 0
    for _, name in ipairs(peripheral.getNames()) do
        if not isExcluded(config, name) then
            local wrapped = peripheral.wrap(name)
            local types = peripheralTypes(name)
            -- Requiring both methods avoids accidentally treating the Stock
            -- Ticker, a modem or another machine as warehouse storage.
            if wrapped and type(wrapped.list) == "function"
                    and type(wrapped.size) == "function"
                    and not (type(wrapped.importItem) == "function"
                        and type(wrapped.exportItem) == "function") then
                -- Inventory Manager transfers address inventories by their
                -- wired-network peripheral name. Local side aliases such as
                -- "left" are ambiguous and commonly fail in importItem and
                -- exportItem, so never advertise them as usable storage.
                if config.requireNamedInventories ~= false and LOCAL_SIDES[name] then
                    ignoredLocalInventories = ignoredLocalInventories + 1
                else
                    local kind = isItemVault(name, types)
                        and "item_vault" or "inventory"
                    local duplicate = false
                    if kind == "item_vault"
                            and config.deduplicateItemVaults ~= false then
                        local snapshot = vaultSnapshot(wrapped)
                        if snapshot and vaultSnapshots[snapshot] then
                            duplicate = true
                            duplicateEndpoints = duplicateEndpoints + 1
                        elseif snapshot then
                            vaultSnapshots[snapshot] = name
                        end
                    end
                    if not duplicate then inventories[#inventories + 1] = {
                        name = name,
                        peripheral = wrapped,
                        kind = kind
                    } end
                end
            end
        end
    end
    table.sort(inventories, function(a, b) return a.name < b.name end)
    return inventories, duplicateEndpoints, ignoredLocalInventories
end

local function normalizeEnchantments(detail)
    local enchantments = {}
    for _, enchantment in pairs(type(detail) == "table"
            and type(detail.enchantments) == "table" and detail.enchantments or {}) do
        if type(enchantment) == "table" then
            enchantments[#enchantments + 1] = {
                name = enchantment.name,
                displayName = enchantment.displayName,
                level = tonumber(enchantment.level) or 1
            }
        end
    end
    table.sort(enchantments, function(a, b)
        return tostring(a.name or a.displayName) < tostring(b.name or b.displayName)
    end)
    return enchantments
end

local function itemVariant(stack, detail)
    detail = type(detail) == "table" and detail or stack
    local enchantments = normalizeEnchantments(detail)
    local enchantmentParts = {}
    for _, enchantment in ipairs(enchantments) do
        enchantmentParts[#enchantmentParts + 1] = table.concat({
            tostring(enchantment.name or enchantment.displayName or ""),
            tostring(enchantment.level or 1)
        }, "@")
    end
    return table.concat({
        tostring(stack.name),
        tostring(stack.nbt or ""),
        tostring(detail.displayName or stack.displayName or stack.label or ""),
        tostring(detail.damage or ""),
        table.concat(enchantmentParts, ",")
    }, "|"), enchantments
end

local function compactItemDetail(stack, detail)
    detail = type(detail) == "table" and detail or stack
    return {
        displayName = detail.displayName or stack.displayName or stack.label,
        damage = detail.damage or stack.damage,
        enchantments = normalizeEnchantments(detail)
    }
end

local ENCHANTABLE_NAME_SUFFIXES = {
    "_sword", "_pickaxe", "_axe", "_shovel", "_hoe",
    "_helmet", "_chestplate", "_leggings", "_boots",
    "bow", "crossbow", "trident", "mace", "elytra", "shield",
    "fishing_rod", "shears", "flint_and_steel", "brush",
    "enchanted_book", "_hammer", "_drill", "_saw", "_knife",
    "_dagger", "_spear", "_staff", "_wand", "_cannon"
}

local function needsItemDetail(stack, config)
    if type(stack) ~= "table" then return false end
    config = type(config) == "table" and config or {}
    -- list() normally exposes only registry id/count/NBT. Indexing the compact
    -- detail for every occupied slot lets Unicode-aware servers supply the
    -- player's real localized display name without shipping an enormous
    -- dictionary for the whole modpack.
    if config.indexAllItemNames ~= false then return true end
    if stack.nbt ~= nil then return true end
    local name = tostring(stack.name or ""):lower()
    local path = name:match("^[^:]+:(.+)$") or name
    for _, suffix in ipairs(ENCHANTABLE_NAME_SUFFIXES) do
        if path:sub(-#suffix) == suffix then return true end
    end
    -- Modpacks can add enchantable items with unusual registry names. Extra
    -- plain-text hints may be supplied without making every vault slot costly.
    for _, hint in ipairs(config.detailedItemPatterns or {}) do
        if name:find(tostring(hint):lower(), 1, true) then return true end
    end
    return false
end

local function sortedSlotIndexes(slots)
    local indexes = {}
    for slot in pairs(slots) do indexes[#indexes + 1] = slot end
    table.sort(indexes, function(a, b)
        return (tonumber(a) or 0) < (tonumber(b) or 0)
    end)
    return indexes
end

local function itemDetailCachePath(config)
    if config.itemDetailCacheFile == false then return nil end
    local path = tostring(config.itemDetailCacheFile or ITEM_DETAIL_CACHE_FILE)
    return path ~= "" and path or ITEM_DETAIL_CACHE_FILE
end

local function itemStackSignature(stack)
    if type(stack) ~= "table" or not stack.name then return nil end
    return table.concat({
        tostring(stack.name), tostring(stack.count or 0),
        tostring(stack.nbt or "")
    }, "|")
end

local function itemDetailCacheKey(inventoryName, slot)
    return tostring(inventoryName) .. ":" .. tostring(slot)
end

local function loadItemDetailCache(config)
    local path = itemDetailCachePath(config)
    if not path then return {} end
    local raw = util.readTable(path, {})
    if raw.version ~= ITEM_DETAIL_CACHE_VERSION
            or type(raw.entries) ~= "table" then return {} end
    local entries = {}
    for key, entry in pairs(raw.entries) do
        if type(key) == "string" and type(entry) == "table"
                and type(entry.signature) == "string"
                and type(entry.detail) == "table"
                and type(entry.inventory) == "string"
                and tonumber(entry.slot) then
            entries[key] = {
                signature = entry.signature,
                detail = entry.detail,
                inventory = entry.inventory,
                slot = tonumber(entry.slot),
                time = tonumber(entry.time) or 0
            }
        end
    end
    return entries
end

local function markItemDetailCacheDirty(state)
    state.itemDetailCacheDirty = true
    -- Keep the first deadline. Moving it after every small indexing batch
    -- would prevent a continuously growing cache from ever being saved.
    if not state.itemDetailCacheSaveAt then
        state.itemDetailCacheSaveAt = util.epoch() + ITEM_DETAIL_CACHE_SAVE_DELAY_MS
    end
end

local function scheduleBackgroundIndex(state, delay)
    state.backgroundIndexing = true
    local requestedAt = util.epoch() + (tonumber(delay) or 0)
    if not state.backgroundIndexAt or requestedAt < state.backgroundIndexAt then
        state.backgroundIndexAt = requestedAt
    end
end

local function saveItemDetailCache(state, force)
    if not state.itemDetailCacheDirty then return true end
    local now = util.epoch()
    if not force and now < (state.itemDetailCacheSaveAt or now) then return true end
    local path = itemDetailCachePath(state.config)
    if not path then
        state.itemDetailCacheDirty = false
        return true
    end
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
    local temp = path .. ".tmp"
    local ok, err = util.writeTable(temp, {
        version = ITEM_DETAIL_CACHE_VERSION,
        savedAt = now,
        entries = state.itemDetailCache
    })
    if not ok then
        state.itemDetailCacheError = tostring(err or "cannot write cache")
        state.itemDetailCacheSaveAt = now + 5000
        return false
    end
    local moved, moveError = pcall(function()
        if fs.exists(path) then fs.delete(path) end
        fs.move(temp, path)
    end)
    if not moved then
        state.itemDetailCacheError = tostring(moveError)
        state.itemDetailCacheSaveAt = now + 5000
        return false
    end
    state.itemDetailCacheDirty = false
    state.itemDetailCacheSaveAt = nil
    state.itemDetailCacheError = nil
    return true
end

local function invalidateChangedItemDetails(state, inventory)
    if not inventory then return end
    -- Reindex even if this was a previously empty slot and therefore had no
    -- cache entry to invalidate.
    scheduleBackgroundIndex(state, 0)
    local ok, slots = pcall(inventory.peripheral.list)
    if not ok or type(slots) ~= "table" then return end
    local changed = false
    for key, cached in pairs(state.itemDetailCache or {}) do
        if cached.inventory == inventory.name then
            local current = slots[tonumber(cached.slot)]
            if itemStackSignature(current) ~= cached.signature then
                state.itemDetailCache[key] = nil
                changed = true
            end
        end
    end
    if changed then markItemDetailCacheDirty(state) end
end

local function itemDetailCacheCount(state)
    local count = 0
    for _ in pairs(state.itemDetailCache or {}) do count = count + 1 end
    return count
end

local function scanInventories(state)
    state.itemDetailCache = state.itemDetailCache or {}
    local merged = {}
    local detailCalls = 0
    local detailsPending = false
    local seenCacheKeys = {}
    local scannedInventories = {}
    local maxCacheAge = tonumber(state.config.itemDetailCacheMaxAge)
        or ITEM_DETAIL_CACHE_MAX_AGE_SECONDS
    local maxDetailCalls = math.max(1, math.min(
        tonumber(state.config.itemDetailCallsPerScan)
            or ITEM_DETAIL_CALLS_PER_SCAN, 8))
    for _, inventory in ipairs(state.inventories) do
        local ok, slots = pcall(inventory.peripheral.list)
        if ok and type(slots) == "table" then
            scannedInventories[inventory.name] = true
            for _, slot in ipairs(sortedSlotIndexes(slots)) do
                local stack = slots[slot]
                if type(stack) == "table" and stack.name then
                    local detail = stack
                    local detailPending = false
                    if needsItemDetail(stack, state.config)
                            and type(inventory.peripheral.getItemDetail) == "function" then
                        local cacheKey = itemDetailCacheKey(inventory.name, slot)
                        local signature = itemStackSignature(stack)
                        seenCacheKeys[cacheKey] = true
                        local cached = state.itemDetailCache[cacheKey]
                        if cached and cached.signature == signature
                                and (maxCacheAge <= 0 or util.epoch() - cached.time
                                    < maxCacheAge * 1000) then
                            detail = cached.detail
                        elseif detailCalls < maxDetailCalls then
                            detailCalls = detailCalls + 1
                            local detailOk, value = pcall(
                                inventory.peripheral.getItemDetail, slot)
                            if detailOk and type(value) == "table" then detail = value end
                            detail = compactItemDetail(stack, detail)
                            -- Cache failures as the basic stack too. Otherwise
                            -- an unsupported inventory would be retried forever.
                            state.itemDetailCache[cacheKey] = {
                                signature = signature, detail = detail,
                                inventory = inventory.name, slot = tonumber(slot),
                                time = util.epoch()
                            }
                            markItemDetailCacheDirty(state)
                        else
                            detailPending = true
                            detailsPending = true
                        end
                    end

                    local variant, enchantments = itemVariant(stack, detail)
                    local item = merged[variant]
                    if not item then
                        item = {
                            variant = variant,
                            name = stack.name,
                            displayName = detail.displayName
                                or stack.displayName or stack.label,
                            count = 0,
                            enchantments = enchantments,
                            enchanted = #enchantments > 0,
                            detailPending = detailPending,
                            sources = {}
                        }
                        merged[variant] = item
                    end
                    item.detailPending = item.detailPending or detailPending
                    item.count = item.count + (tonumber(stack.count) or 0)
                    item.sources[#item.sources + 1] = {
                        inventory = inventory.name,
                        slot = tonumber(slot),
                        count = tonumber(stack.count) or 0
                    }
                end
            end
        end
    end
    local cachePruned = false
    for key, cached in pairs(state.itemDetailCache) do
        if scannedInventories[cached.inventory] and not seenCacheKeys[key] then
            state.itemDetailCache[key] = nil
            cachePruned = true
        end
    end
    if cachePruned then markItemDetailCacheDirty(state) end
    return merged, detailsPending
end

local function runBackgroundIndex(state, now)
    if not state.backgroundIndexAt or now < state.backgroundIndexAt then return end
    if #state.inventories == 0 then
        state.backgroundIndexing = false
        state.backgroundIndexAt = nil
        state.stockVariants = {}
        return
    end

    local stock, detailsPending = scanInventories(state)
    state.stockVariants = stock
    state.backgroundIndexing = detailsPending
    state.backgroundIndexAt = detailsPending
        and (now + BACKGROUND_INDEX_INTERVAL_MS) or nil
end

local function movedAmount(value)
    if type(value) == "table" then
        return tonumber(value.moved or value.count or value.transferred) or 0
    end
    return tonumber(value) or 0
end

local function playerInventory(manager)
    local okList, raw = pcall(manager.list)
    if not okList or type(raw) ~= "table" then
        return nil, tostring(raw or "cannot read player inventory")
    end
    local capacity = 0
    if type(manager.size) == "function" then
        local okSize, value = pcall(manager.size)
        if okSize then capacity = math.max(0, tonumber(value) or 0) end
    end
    local slots = {}
    for key, stack in pairs(raw) do
        local slot = tonumber(key)
        if slot and type(stack) == "table" and stack.name then
            local detail = stack
            if needsItemDetail(stack, {})
                    and type(manager.getItemDetail) == "function" then
                local okDetail, value = pcall(manager.getItemDetail, slot)
                if okDetail and type(value) == "table" then detail = value end
            end
            local enchantments = normalizeEnchantments(detail)
            slots[#slots + 1] = i18n.localizeItem({
                slot = slot,
                name = stack.name,
                displayName = detail.displayName
                    or stack.displayName or stack.label,
                count = tonumber(stack.count) or 0,
                enchantments = enchantments,
                enchanted = #enchantments > 0
            })
            capacity = math.max(capacity, slot)
        end
    end
    table.sort(slots, function(a, b) return a.slot < b.slot end)
    return { slots = slots, capacity = capacity }
end

local function classifyInventoryError(value)
    local message = tostring(value or "unknown Inventory Manager error")
    local lower = message:lower()
    if lower:find("does not exist", 1, true) then
        return "different_network", message
    elseif lower:find("memory card", 1, true)
            or lower:find("bound to a player", 1, true) then
        return "manager_owner", message
    elseif lower:find("disabled in the config", 1, true) then
        return "transfers_disabled", message
    elseif lower:find("not an inventory", 1, true) then
        return "unsupported_inventory", message
    end
    return "manager_error", message
end

-- Inventory Manager resolves target names through the peripheral connection
-- on which the method was called. peripheral.getNames() can also contain
-- inventories from a second wired network attached to the same computer. A
-- zero-count import resolves the target without moving an item, so it is a
-- safe compatibility probe for Advanced Peripherals 0.8.2a.
local function compatibleInventories(manager, inventories)
    if not manager then return inventories, {}, nil end
    local compatible, rejected, issue = {}, {}, nil
    for _, inventory in ipairs(inventories) do
        local ok, value = pcall(manager.importItem, inventory.name, { count = 0 })
        if ok then
            compatible[#compatible + 1] = inventory
        else
            local kind, message = classifyInventoryError(value)
            rejected[#rejected + 1] = {
                name = inventory.name, issue = kind, error = message
            }
            issue = issue or kind
        end
    end
    return compatible, rejected, issue
end

local function refreshInventories(state)
    local discovered
    discovered, state.duplicateEndpoints, state.ignoredLocalInventories
        = locateInventories(state.config)
    state.discoveredInventoryCount = #discovered
    state.inventories, state.incompatibleInventories, state.inventoryIssue
        = compatibleInventories(state.manager, discovered)
end

local function noInventoryError(state)
    if #(state.incompatibleInventories or {}) > 0 then
        if state.inventoryIssue == "different_network" then
            return "storage and Inventory Manager are on different wired networks; connect both to the same cable"
        elseif state.inventoryIssue == "manager_owner" then
            return "Inventory Manager has no bound player; insert a bound Memory Card and keep that player online"
        elseif state.inventoryIssue == "transfers_disabled" then
            return "item transfer is disabled in the Advanced Peripherals server config"
        elseif state.inventoryIssue == "unsupported_inventory" then
            return "the connected storage can be listed but Inventory Manager cannot transfer items to it"
        end
        return "Inventory Manager cannot access the connected storage"
    end
    if (state.ignoredLocalInventories or 0) > 0 then
        return "only side inventories found; connect storage through an active wired modem"
    end
    return "no named wired inventories found"
end

local function refreshPeripherals(state)
    state.ticker = locateTicker()
    state.manager, state.managerName = locateManager()
    refreshInventories(state)
end

local function countInventoryKind(inventories, kind)
    local count = 0
    for _, inventory in ipairs(inventories) do
        if inventory.kind == kind then count = count + 1 end
    end
    return count
end

local function inventoryByName(state, name)
    for _, inventory in ipairs(state.inventories or {}) do
        if inventory.name == name then return inventory end
    end
    return nil
end

local function response(config, recipient, id, ok, data, err)
    rednet.send(recipient, {
        kind = "response", id = id, ok = ok, data = data,
        error = err, key = config.sharedKey
    }, config.protocol)
end

local function requestStock(ticker, address, itemName, count)
    local filter = { name = itemName, _requestCount = count }
    local ok, result, detail = pcall(ticker.requestFiltered, address, filter)
    if not ok then return nil, result end
    if result == nil then return nil, detail or "request rejected" end
    if type(result) == "table" then
        return tonumber(result.count or result.requested or result.amount) or count
    end
    return tonumber(result) or count
end

local function inspectMachine(config, payload)
    local key = ("%s:%d:%d:%d"):format(
        payload.dimension or "minecraft:overworld",
        tonumber(payload.x) or 0, tonumber(payload.y) or 0, tonumber(payload.z) or 0)
    local peripheralName = config.machines and config.machines[key]
    if not peripheralName then
        return { message = "No provider registered", key = key }
    end
    if not peripheral.isPresent(peripheralName) then
        return { message = "Provider offline", key = key }
    end
    local machine = peripheral.wrap(peripheralName)
    local result = { provider = peripheralName }

    if type(machine.size) == "function" and type(machine.list) == "function" then
        local okSize, capacity = pcall(machine.size)
        local okList, list = pcall(machine.list)
        if okSize and okList then
            local used = 0
            for _ in pairs(list or {}) do used = used + 1 end
            result.capacity = capacity
            result.usedSlots = used
            result.fullness = capacity > 0 and used / capacity or 0
        end
    end

    local data
    if type(machine.getBlockData) == "function" then
        local ok, value = pcall(machine.getBlockData)
        if ok then data = value end
    end
    if type(data) == "table" then
        local progress = tonumber(data.CookTime or data.cookTime or data.cookingProgress)
        local total = tonumber(data.CookTimeTotal or data.cookTimeTotal or data.cookingTotalTime)
        if progress and total and total > 0 then result.progress = progress / total end
        result.burnTime = tonumber(data.BurnTime or data.burnTime or data.litTime)
    elseif type(machine.getProgress) == "function" then
        local ok, value = pcall(machine.getProgress)
        if ok and tonumber(value) then
            result.progress = tonumber(value)
            if result.progress > 1 then result.progress = result.progress / 100 end
        end
    end
    if not result.capacity and not result.progress then result.message = "Provider has no supported data" end
    return result
end

local function printStatus(state)
    term.clear()
    term.setCursorPos(1, 1)
    print("M2OS STORAGE BRIDGE")
    print("Computer: " .. os.getComputerID())
    print("Modem:   " .. (state.modemName or "NOT FOUND"))
    print("Ticker:  " .. (state.ticker and "ONLINE"
        or (state.config.enableCreateCrafting and "NOT FOUND" or "OPTIONAL")))
    print("Manager: " .. (state.manager
        and ("ONLINE (%s)"):format(state.managerName or "unknown")
        or "NOT FOUND"))
    print(("Storage: %d usable / %d found (%d vaults)"):format(
        #state.inventories, state.discoveredInventoryCount or #state.inventories,
        countInventoryKind(state.inventories, "item_vault")))
    if #(state.incompatibleInventories or {}) > 0 then
        print(("Blocked: %d; not on Manager wired network"):format(
            #state.incompatibleInventories))
    end
    if (state.duplicateEndpoints or 0) > 0 then
        print(("Aliases: %d duplicate vault endpoint(s) ignored"):format(
            state.duplicateEndpoints))
    end
    if (state.ignoredLocalInventories or 0) > 0 then
        print(("Ignored: %d side inventory; use wired name"):format(
            state.ignoredLocalInventories))
    end
    local indexStatus = {}
    if state.backgroundIndexing then indexStatus[#indexStatus + 1] = "indexing" end
    if state.itemDetailCacheDirty then indexStatus[#indexStatus + 1] = "saving" end
    print(("Index:   %d cached%s"):format(itemDetailCacheCount(state),
        #indexStatus > 0 and (" (" .. table.concat(indexStatus, ", ") .. ")") or ""))
    if state.itemDetailCacheError then
        print("Cache:   " .. util.short(state.itemDetailCacheError, 38))
    end
    print("Pending: " .. tostring(#state.transactions))
    print("")
    print(state.lastMessage or "Waiting for requests...")
    print("")
    print("Ctrl+T to stop")
end

local function handleRequest(state, sender, message)
    local config = state.config
    if message.key ~= config.sharedKey then return end
    if not trusted(config, sender) then
        response(config, sender, message.id, false, nil, "computer is not trusted")
        return
    end
    local operation = message.operation
    local payload = type(message.payload) == "table" and message.payload or {}
    state.lastMessage = ("#%d %s"):format(sender, tostring(operation))

    if operation == "ping" then
        response(config, sender, message.id, true, {
            ticker = state.ticker ~= nil, manager = state.manager ~= nil,
            inventories = #state.inventories, direct = true,
            itemVaults = countInventoryKind(state.inventories, "item_vault"),
            ignoredLocalInventories = state.ignoredLocalInventories or 0,
            createCrafting = config.enableCreateCrafting == true
        })
    elseif operation == "player_inventory" then
        if not state.manager then
            response(config, sender, message.id, false, nil, "Inventory Manager not found")
            return
        end
        local inventory, err = playerInventory(state.manager)
        if not inventory then
            response(config, sender, message.id, false, nil, err)
            return
        end
        response(config, sender, message.id, true, inventory)
    elseif operation == "stock" then
        refreshInventories(state)
        if #state.inventories == 0 then
            response(config, sender, message.id, false, nil, noInventoryError(state))
            return
        end
        local limit = math.max(1, math.min(tonumber(payload.limit) or 128, 128))
        local stock, detailsPending = scanInventories(state)
        state.stockVariants = stock
        if detailsPending then
            scheduleBackgroundIndex(state, BACKGROUND_INDEX_INTERVAL_MS)
        else
            state.backgroundIndexing = false
            state.backgroundIndexAt = nil
        end
        response(config, sender, message.id, true, {
            items = normalizeStock(stock, payload.query, limit),
            inventories = #state.inventories,
            itemVaults = countInventoryKind(state.inventories, "item_vault"),
            detailsPending = detailsPending
        })
    elseif operation == "deposit" then
        if not state.manager then
            response(config, sender, message.id, false, nil, "Inventory Manager not found")
            return
        end
        refreshInventories(state)
        if #state.inventories == 0 then
            response(config, sender, message.id, false, nil, noInventoryError(state))
            return
        end
        local itemName = payload.name
        local fromSlot
        local count
        if payload.slot ~= nil then
            fromSlot = math.floor(tonumber(payload.slot) or 0)
            local player, err = playerInventory(state.manager)
            if not player then
                response(config, sender, message.id, false, nil, err)
                return
            end
            local stack
            for _, entry in ipairs(player.slots) do
                if entry.slot == fromSlot then stack = entry break end
            end
            if not stack then
                response(config, sender, message.id, false, nil,
                    "player inventory slot is empty")
                return
            end
            if itemName and itemName ~= stack.name then
                response(config, sender, message.id, false, nil,
                    "player inventory changed; try again")
                return
            end
            itemName = stack.name
            -- A slot deposit always means the complete current stack. The
            -- client cannot accidentally request a single item from it.
            count = math.max(1, math.floor(tonumber(stack.count) or 1))
        else
            count = math.max(1, math.floor(tonumber(payload.count) or 1))
        end
        if payload.hand and not itemName and type(state.manager.getItemInHand) == "function" then
            local handOk, hand = pcall(state.manager.getItemInHand)
            if handOk and type(hand) == "table" then itemName = hand.name end
        end
        if not itemName then
            response(config, sender, message.id, false, nil, "hand is empty or item name is missing")
            return
        end
        local moved, lastError = 0, nil
        for _, inventory in ipairs(state.inventories) do
            if moved >= count then break end
            local filter = { name = itemName, count = count - moved }
            if fromSlot then filter.fromSlot = fromSlot end
            local ok, value = pcall(state.manager.exportItem, inventory.name, filter)
            if ok then
                local amount = movedAmount(value)
                moved = moved + amount
                if amount > 0 then invalidateChangedItemDetails(state, inventory) end
            else
                lastError = value
            end
        end
        if moved > 0 then
            response(config, sender, message.id, true, {
                requested = count, moved = moved, remaining = math.max(0, count - moved),
                complete = moved >= count, slot = fromSlot
            })
        else
            response(config, sender, message.id, false, nil,
                lastError or "no storage accepted the item")
        end
    elseif operation == "withdraw" then
        if not state.manager then
            response(config, sender, message.id, false, nil, "Inventory Manager not found")
            return
        end
        if not payload.name then
            response(config, sender, message.id, false, nil, "item name is required")
            return
        end
        refreshInventories(state)
        if #state.inventories == 0 then
            response(config, sender, message.id, false, nil, noInventoryError(state))
            return
        end
        local count = math.max(1, math.floor(tonumber(payload.count) or 1))
        local moved, lastError = 0, nil
        local variant = payload.variant
            and state.stockVariants[payload.variant] or nil
        if payload.variant and not variant then
            response(config, sender, message.id, false, nil,
                "item variant is stale; refresh storage and try again")
            return
        end
        if variant then
            for _, source in ipairs(variant.sources or {}) do
                if moved >= count then break end
                local sourceInventory = inventoryByName(state, source.inventory)
                local sourcePeripheral = sourceInventory and sourceInventory.peripheral
                local matches, currentStack, currentDetail = false, nil, nil
                if sourcePeripheral then
                    local listOk, currentSlots = pcall(sourcePeripheral.list)
                    currentStack = listOk and type(currentSlots) == "table"
                        and currentSlots[source.slot] or nil
                    matches = type(currentStack) == "table"
                    currentDetail = currentStack
                end
                if matches and needsItemDetail(currentStack, config)
                        and type(sourcePeripheral.getItemDetail) == "function" then
                    local detailOk, detail = pcall(
                        sourcePeripheral.getItemDetail, source.slot)
                    if detailOk and type(detail) == "table" then
                        currentDetail = detail
                    else
                        matches = false
                    end
                end
                if matches then
                    matches = itemVariant(currentStack, currentDetail) == payload.variant
                end
                if matches then
                    local ok, value = pcall(state.manager.importItem,
                        source.inventory, {
                            name = payload.name, fromSlot = source.slot,
                            count = count - moved
                        })
                    if ok then
                        local amount = movedAmount(value)
                        moved = moved + amount
                        if amount > 0 then
                            invalidateChangedItemDetails(state, sourceInventory)
                        end
                    else
                        lastError = value
                    end
                end
            end
        else
            for _, inventory in ipairs(state.inventories) do
                if moved >= count then break end
                local ok, value = pcall(state.manager.importItem, inventory.name, {
                    name = payload.name, count = count - moved
                })
                if ok then
                    local amount = movedAmount(value)
                    moved = moved + amount
                    if amount > 0 then invalidateChangedItemDetails(state, inventory) end
                else
                    lastError = value
                end
            end
        end
        if moved > 0 then
            response(config, sender, message.id, true, {
                requested = count, moved = moved, remaining = math.max(0, count - moved),
                mode = "direct"
            })
        else
            response(config, sender, message.id, false, nil,
                lastError or "item not found or player inventory is full")
        end
    elseif operation == "craft" then
        if config.enableCreateCrafting ~= true then
            response(config, sender, message.id, false, nil,
                "Create crafting is disabled in direct storage mode")
            return
        end
        if not state.ticker then
            response(config, sender, message.id, false, nil, "Create Stock Ticker not found")
            return
        end
        if not payload.name then
            response(config, sender, message.id, false, nil, "item name is required")
            return
        end
        local count = math.max(1, math.floor(tonumber(payload.count) or 1))
        local requested, err = requestStock(state.ticker, config.outputAddress, payload.name, count)
        if not requested then
            response(config, sender, message.id, false, nil, err)
            return
        end
        if requested <= 0 then
            response(config, sender, message.id, false, nil,
                "Create network did not accept this item request")
            return
        end
        if not state.manager or not config.outputInventory or config.outputInventory == "" then
            response(config, sender, message.id, true, {
                requested = requested, moved = 0, delivery = "output inventory",
                mode = operation
            })
            return
        end
        state.transactions[#state.transactions + 1] = {
            sender = sender, id = message.id, name = payload.name,
            requested = requested, remaining = requested, moved = 0,
            mode = operation, nextTry = util.epoch() + 500,
            deadline = util.epoch() + (config.transactionTimeout or 45) * 1000
        }
    elseif operation == "inspect" then
        response(config, sender, message.id, true, inspectMachine(config, payload))
    else
        response(config, sender, message.id, false, nil, "unknown operation " .. tostring(operation))
    end
end

local function pollTransactions(state, now)
    local config = state.config
    for index = #state.transactions, 1, -1 do
        local tx = state.transactions[index]
        local finished = false
        if now >= tx.nextTry then
            tx.nextTry = now + 500
            local ok, moved = pcall(state.manager.importItem, config.outputInventory,
                { name = tx.name, count = tx.remaining })
            if ok then
                moved = tonumber(moved) or 0
                tx.moved = tx.moved + moved
                tx.remaining = math.max(0, tx.remaining - moved)
                if moved > 0 then
                    invalidateChangedItemDetails(state,
                        inventoryByName(state, config.outputInventory))
                end
            end
            if tx.remaining <= 0 then finished = true end
        end
        if finished or now >= tx.deadline then
            response(config, tx.sender, tx.id, tx.moved > 0 or tx.requested == 0, {
                requested = tx.requested, moved = tx.moved,
                timedOut = not finished, mode = tx.mode
            }, tx.moved == 0 and "no items reached the output buffer" or nil)
            table.remove(state.transactions, index)
        end
    end
end

function Server.run(config)
    local modemName = util.findWirelessModem()
    if not modemName then error("Wireless/Ender Modem not found", 0) end
    if not rednet.isOpen(modemName) then rednet.open(modemName) end

    local state = {
        config = config, modemName = modemName, ticker = nil, manager = nil,
        managerName = nil, inventories = {}, incompatibleInventories = {},
        discoveredInventoryCount = 0, inventoryIssue = nil,
        duplicateEndpoints = 0, ignoredLocalInventories = 0,
        transactions = {}, lastMessage = nil,
        itemDetailCache = loadItemDetailCache(config),
        itemDetailCacheDirty = false, itemDetailCacheSaveAt = nil,
        itemDetailCacheError = nil, stockVariants = {},
        backgroundIndexing = false, backgroundIndexAt = nil
    }
    refreshPeripherals(state)
    scheduleBackgroundIndex(state, 0)
    runBackgroundIndex(state, util.epoch())
    printStatus(state)
    local timer = os.startTimer(0.25)

    while true do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then break end
        if event[1] == "rednet_message" and event[4] == config.protocol
                and type(event[3]) == "table" then
            local sender, message = event[2], event[3]
            if message.kind == "discover" and message.key == config.sharedKey then
                state.lastMessage = ("#%d discover"):format(sender)
                rednet.send(sender, {
                    kind = "hello", key = config.sharedKey,
                    name = "M2OS Create Bridge", version = 7,
                    inventories = #state.inventories,
                    detectedInventories = state.discoveredInventoryCount,
                    incompatibleInventories = #state.incompatibleInventories,
                    itemVaults = countInventoryKind(state.inventories, "item_vault"),
                    ignoredLocalInventories = state.ignoredLocalInventories or 0
                }, config.protocol)
            elseif message.kind == "request" and message.id then
                handleRequest(state, sender, message)
            end
            printStatus(state)
        elseif event[1] == "timer" and event[2] == timer then
            local now = util.epoch()
            pollTransactions(state, now)
            runBackgroundIndex(state, now)
            saveItemDetailCache(state, false)
            printStatus(state)
            timer = os.startTimer(0.25)
        elseif event[1] == "peripheral" or event[1] == "peripheral_detach" then
            refreshPeripherals(state)
            scheduleBackgroundIndex(state, 0)
            printStatus(state)
        end
    end
    saveItemDetailCache(state, true)
    if rednet.isOpen(modemName) then rednet.close(modemName) end
    term.clear()
    term.setCursorPos(1, 1)
    print("M2OS Create Bridge stopped")
end

return Server
