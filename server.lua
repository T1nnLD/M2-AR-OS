local util = require("m2os.lib.util")

local Server = {}

local function trusted(config, sender)
    if not config.trustedIds or #config.trustedIds == 0 then return true end
    for _, id in ipairs(config.trustedIds) do
        if id == sender then return true end
    end
    return false
end

local function normalizeStock(raw, query, limit)
    local items = {}
    query = tostring(query or ""):lower()
    for key, value in pairs(type(raw) == "table" and raw or {}) do
        local item
        if type(value) == "table" then
            item = {
                name = value.name or (type(value.item) == "table" and value.item.name) or
                    (type(key) == "string" and key or nil),
                displayName = value.displayName or value.label,
                count = tonumber(value.count or value.amount or value.total) or 0,
                craftable = value.craftable == true or value.isCraftable == true
            }
        elseif type(key) == "string" then
            item = { name = key, count = tonumber(value) or 0 }
        end
        if item and item.name then
            local haystack = (item.name .. " " .. (item.displayName or "")):lower()
            if query == "" or haystack:find(query, 1, true) then items[#items + 1] = item end
        end
    end
    table.sort(items, function(a, b)
        if a.count ~= b.count then return a.count > b.count end
        return a.name < b.name
    end)
    while #items > (limit or 256) do table.remove(items) end
    return items
end

local function locateTicker()
    return util.findPeripheral({ "stock", "requestFiltered" },
        { "Create_StockTicker", "create:stock_ticker", "stockTicker" })
end

local function locateManager()
    return util.findPeripheral({ "importItem", "exportItem" },
        { "inventoryManager", "inventory_manager" })
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
    print("M2OS CREATE BRIDGE")
    print("Computer: " .. os.getComputerID())
    print("Modem:   " .. (state.modemName or "NOT FOUND"))
    print("Ticker:  " .. (state.ticker and "ONLINE" or "NOT FOUND"))
    print("Manager: " .. (state.manager and "ONLINE" or "NOT FOUND"))
    print("Address: " .. tostring(state.config.outputAddress))
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
            outputAddress = config.outputAddress
        })
    elseif operation == "stock" then
        if not state.ticker then
            response(config, sender, message.id, false, nil, "Create Stock Ticker not found")
            return
        end
        local ok, raw = pcall(state.ticker.stock, true)
        if not ok then
            response(config, sender, message.id, false, nil, raw)
        else
            response(config, sender, message.id, true, {
                items = normalizeStock(raw, payload.query, tonumber(payload.limit) or 256)
            })
        end
    elseif operation == "deposit" then
        if not state.manager then
            response(config, sender, message.id, false, nil, "Inventory Manager not found")
            return
        end
        if not config.inputInventory or config.inputInventory == "" then
            response(config, sender, message.id, false, nil, "inputInventory is not configured")
            return
        end
        local count = math.max(1, math.floor(tonumber(payload.count) or 1))
        local itemName = payload.name
        if payload.hand and not itemName and type(state.manager.getItemInHand) == "function" then
            local handOk, hand = pcall(state.manager.getItemInHand)
            if handOk and type(hand) == "table" then itemName = hand.name end
        end
        if not itemName then
            response(config, sender, message.id, false, nil, "hand is empty or item name is missing")
            return
        end
        local filter = { name = itemName, count = count }
        local ok, moved, moveError = pcall(state.manager.exportItem, config.inputInventory, filter)
        if ok and moved ~= nil then
            response(config, sender, message.id, true, { moved = tonumber(moved) or 0 })
        else
            response(config, sender, message.id, false, nil, moveError or moved)
        end
    elseif operation == "withdraw" or operation == "craft" then
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

    local ticker = locateTicker()
    local manager = locateManager()
    local state = {
        config = config, modemName = modemName, ticker = ticker, manager = manager,
        transactions = {}, lastMessage = nil
    }
    printStatus(state)
    local timer = os.startTimer(0.25)

    while true do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then break end
        if event[1] == "rednet_message" and event[4] == config.protocol
                and type(event[3]) == "table" then
            local sender, message = event[2], event[3]
            if message.kind == "discover" and message.key == config.sharedKey then
                rednet.send(sender, {
                    kind = "hello", key = config.sharedKey,
                    name = "M2OS Create Bridge", version = 1
                }, config.protocol)
            elseif message.kind == "request" and message.id then
                handleRequest(state, sender, message)
            end
            printStatus(state)
        elseif event[1] == "timer" and event[2] == timer then
            pollTransactions(state, util.epoch())
            printStatus(state)
            timer = os.startTimer(0.25)
        elseif event[1] == "peripheral" or event[1] == "peripheral_detach" then
            state.ticker = locateTicker()
            state.manager = locateManager()
            printStatus(state)
        end
    end
    if rednet.isOpen(modemName) then rednet.close(modemName) end
    term.clear()
    term.setCursorPos(1, 1)
    print("M2OS Create Bridge stopped")
end

return Server
