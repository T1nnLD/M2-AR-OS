local api = require("m2os.api")
local util = require("m2os.lib.util")

local app = {
    id = "storage",
    name = "Create Storage",
    priority = 20,
    userToggle = false,
    required = true,
    persistent = false
}

local state = {
    modemName = nil,
    serverId = nil,
    pending = {},
    sequence = 0,
    panelOpen = false,
    rows = {},
    status = "OFFLINE",
    selected = 1,
    offset = 1
}

local function openModem(ctx)
    if state.modemName and rednet.isOpen(state.modemName) then return true end
    local name = util.findWirelessModem()
    if not name then
        state.status = "NO WIRELESS MODEM"
        return false
    end
    if not rednet.isOpen(name) then rednet.open(name) end
    state.modemName = name
    return true
end

local function send(ctx, operation, payload, callback)
    if not openModem(ctx) then
        if callback then callback(false, nil, state.status) end
        return nil
    end
    state.sequence = state.sequence + 1
    local id = ("%d:%d:%d"):format(os.getComputerID(), util.epoch(), state.sequence)
    local message = {
        kind = "request",
        id = id,
        key = ctx.config.storage.sharedKey,
        operation = operation,
        payload = payload or {}
    }
    state.pending[id] = { callback = callback, started = util.epoch() }
    if state.serverId then
        rednet.send(state.serverId, message, ctx.config.storage.protocol)
    else
        rednet.broadcast(message, ctx.config.storage.protocol)
    end
    return id
end

local function discover(ctx)
    if not openModem(ctx) then return false end
    rednet.broadcast({
        kind = "discover",
        key = ctx.config.storage.sharedKey
    }, ctx.config.storage.protocol)
    state.status = "SEARCHING"
    return true
end

local function sortedStock(stock)
    local rows = {}
    for _, item in pairs(stock or {}) do rows[#rows + 1] = item end
    table.sort(rows, function(a, b)
        if (a.count or 0) ~= (b.count or 0) then return (a.count or 0) > (b.count or 0) end
        return (a.name or "") < (b.name or "")
    end)
    return rows
end

local function drawPanel(ctx)
    ctx.ui.clear()
    if not state.panelOpen then return end
    local width, height = ctx.system.getSize()
    local theme = ctx.config.theme
    local panelW, panelH = math.min(270, width - 30), math.min(176, height - 30)
    local x, y = (width - panelW) / 2, (height - panelH) / 2

    ctx.ui.textureRect(x, y, panelW, panelH, theme.background, 0.90, 70)
    ctx.ui.rectangle(x, y, panelW, 2, theme.purple, 1, 72)
    ctx.ui.rectangle(x, y + panelH - 2, panelW, 2, theme.blue, 1, 72)
    ctx.ui.text(x + 9, y + 7, "CREATE LOGISTICS", theme.white, 1.05, 75)
    ctx.ui.text(x + panelW - 87, y + 8, state.status,
        state.serverId and theme.green or theme.amber, 0.75, 75)

    local maxRows = math.min(ctx.config.storage.maxRows, math.floor((panelH - 50) / 14))
    if #state.rows == 0 then
        ctx.ui.text(x + 10, y + 35, "No stock data", theme.gray, 0.9, 75)
    else
        local last = math.min(#state.rows, state.offset + maxRows - 1)
        for index = state.offset, last do
            local item = state.rows[index]
            local rowY = y + 27 + (index - state.offset) * 14
            if index == state.selected then
                ctx.ui.rectangle(x + 7, rowY - 2, panelW - 14, 13,
                    theme.purple, 0.20, 72)
            elseif index % 2 == 0 then
                ctx.ui.rectangle(x + 7, rowY - 2, panelW - 14, 13,
                    theme.blue, 0.07, 72)
            end
            ctx.ui.text(x + 10, rowY,
                util.short(util.itemLabel(item), 28), theme.white, 0.82, 75)
            ctx.ui.text(x + panelW - 54, rowY,
                tostring(item.count or 0), item.craftable and theme.purple or theme.blue, 0.82, 75)
        end
    end
    ctx.ui.text(x + 9, y + panelH - 18,
        "L:take  R:stack  M:put hand  C:craft", theme.gray, 0.67, 75)
end

local function refresh(ctx, query)
    state.status = state.serverId and "SYNC" or "SEARCHING"
    drawPanel(ctx)
    send(ctx, "stock", { query = query or "", limit = 128 }, function(ok, data, err)
        if ok then
            state.rows = sortedStock(data and data.items)
            state.selected = math.max(1, math.min(state.selected, #state.rows))
            state.offset = math.max(1, math.min(state.offset, state.selected))
            state.status = "ONLINE"
        else
            state.status = "ERROR"
            ctx.notify("Storage: " .. tostring(err), ctx.config.theme.red)
        end
        drawPanel(ctx)
    end)
end

local function togglePanel(ctx)
    state.panelOpen = not state.panelOpen
    ctx.system.setInputMode(state.panelOpen and "storage" or nil)
    drawPanel(ctx)
    if state.panelOpen then refresh(ctx) end
end

function app.start(ctx)
    state.serverId = ctx.config.storage.serverId
    state.pending = {}
    ctx.services.provide("storage", {
        discover = function() return discover(ctx) end,
        status = function()
            return { online = state.serverId ~= nil, serverId = state.serverId, status = state.status }
        end,
        request = function(operation, payload, callback) return send(ctx, operation, payload, callback) end,
        stock = function(query, callback) return send(ctx, "stock", { query = query or "" }, callback) end,
        withdraw = function(item, count, callback)
            return send(ctx, "withdraw", { name = item, count = count or 1 }, callback)
        end,
        deposit = function(item, count, callback)
            return send(ctx, "deposit", { name = item, count = count or 1 }, callback)
        end,
        depositHand = function(count, callback)
            return send(ctx, "deposit", { hand = true, count = count or 64 }, callback)
        end,
        craft = function(item, count, callback)
            return send(ctx, "craft", { name = item, count = count or 1 }, callback)
        end,
        inspect = function(target, callback) return send(ctx, "inspect", target, callback) end,
        show = function() if not state.panelOpen then togglePanel(ctx) end end,
        hide = function() if state.panelOpen then togglePanel(ctx) end end,
        toggle = function() togglePanel(ctx) end
    })
    ctx.menu.add({
        id = "storage.panel", label = "CREATE STORAGE", order = 30,
        checked = function() return state.panelOpen end,
        run = function() togglePanel(ctx) end
    })
    discover(ctx)
end

local function selectedItem()
    return state.rows[state.selected]
end

local function transfer(ctx, operation, count)
    local item = selectedItem()
    if not item then return end
    state.status = operation == "craft" and "CRAFTING" or "DELIVERY"
    drawPanel(ctx)
    send(ctx, operation, { name = item.name, count = count }, function(ok, data, err)
        if ok then
            state.status = "ONLINE"
            ctx.notify(("Storage %s: %s"):format(operation,
                textutils.serialize(data or {})), ctx.config.theme.green)
            refresh(ctx)
        else
            state.status = "ERROR"
            ctx.notify("Storage: " .. tostring(err), ctx.config.theme.red)
            drawPanel(ctx)
        end
    end)
end

function app.onEvent(ctx, event, sender, message, protocol)
    if state.panelOpen then
        if event == "player_mouse_scroll" then
            local direction = tonumber(sender) or 1
            state.selected = math.max(1, math.min(#state.rows,
                state.selected + (direction > 0 and 1 or -1)))
            local page = ctx.config.storage.maxRows
            if state.selected < state.offset then state.offset = state.selected end
            if state.selected >= state.offset + page then
                state.offset = state.selected - page + 1
            end
            drawPanel(ctx)
            return true
        elseif event == "player_mouse_click" then
            local button = tonumber(sender) or 0
            if button == 2 then
                send(ctx, "deposit", { hand = true, count = 64 }, function(ok, data, err)
                    ctx.notify(ok and ("Deposited " .. tostring(data and data.moved or 0))
                        or ("Deposit: " .. tostring(err)),
                        ok and ctx.config.theme.green or ctx.config.theme.red)
                    refresh(ctx)
                end)
            else
                transfer(ctx, "withdraw", button == 1 and 64 or 1)
            end
            return true
        elseif event == "key" and keys then
            local code = tonumber(sender)
            if code == keys.c then transfer(ctx, "craft", 1) return true end
            if code == keys.q then transfer(ctx, "withdraw", 64) return true end
            if code == keys.enter or code == keys.numPadEnter then
                transfer(ctx, "withdraw", 1) return true
            end
            if code == keys.p then
                send(ctx, "deposit", { hand = true, count = 64 }, function(ok, data, err)
                    ctx.notify(ok and ("Deposited " .. tostring(data and data.moved or 0))
                        or ("Deposit: " .. tostring(err)),
                        ok and ctx.config.theme.green or ctx.config.theme.red)
                    refresh(ctx)
                end)
                return true
            end
        elseif event == "keyboard_close" or event == "glasses_key_pressed" then
            togglePanel(ctx)
            return true
        end
    end

    if event ~= "rednet_message" or protocol ~= ctx.config.storage.protocol
            or type(message) ~= "table" then return end
    if message.kind == "hello" and message.key == ctx.config.storage.sharedKey then
        state.serverId = sender
        state.status = "ONLINE"
        if state.panelOpen then refresh(ctx) end
        return
    end
    if message.kind ~= "response" or not message.id then return end
    local pending = state.pending[message.id]
    if not pending then return end
    state.pending[message.id] = nil
    if message.ok then state.serverId = sender end
    if pending.callback then pending.callback(message.ok, message.data, message.error) end
end

function app.update(ctx, now)
    for id, pending in pairs(state.pending) do
        if now - pending.started > 50000 then
            state.pending[id] = nil
            if pending.callback then pending.callback(false, nil, "request timeout") end
        end
    end
end

function app.stop(ctx)
    if ctx.system.getInputMode() == "storage" then ctx.system.setInputMode(nil) end
    ctx.ui.clear()
    state.panelOpen = false
end

api.registerApp(app)
return app
