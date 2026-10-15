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

local MIN_BRIDGE_VERSION = 2
local PANEL_SETTLE_MS = 180

local state = {
    modemName = nil,
    serverId = nil,
    serverVersion = nil,
    pending = {},
    sequence = 0,
    panelOpen = false,
    rows = {},
    status = "OFFLINE",
    statusDetail = nil,
    legacyServerId = nil,
    selected = 1,
    offset = 1,
    drawAt = nil,
    widgets = nil
}

local function objectCall(object, method, ...)
    if not object or type(object[method]) ~= "function" then return false end
    return pcall(object[method], ...)
end

local function bridgeReady()
    return state.serverId ~= nil
        and (tonumber(state.serverVersion) or 0) >= MIN_BRIDGE_VERSION
end

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
    -- Never broadcast operational requests. An old v1 bridge performs a very
    -- expensive full-NBT Stock Ticker query which can take down a large
    -- multiplayer server. Discovery is harmless; all other operations require
    -- the bridge to explicitly advertise the safe protocol version first.
    if not bridgeReady() then
        local reason = state.serverId and "storage bridge update required"
            or "storage bridge not discovered"
        if callback then callback(false, nil, reason) end
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
    rednet.send(state.serverId, message, ctx.config.storage.protocol)
    return id
end

local function discover(ctx)
    if not openModem(ctx) then return false end
    rednet.broadcast({
        kind = "discover",
        key = ctx.config.storage.sharedKey
    }, ctx.config.storage.protocol)
    state.status = "SEARCHING"
    state.statusDetail = "Looking for a compatible storage bridge..."
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

local function updatePanel(ctx)
    local widgets = state.widgets
    if not widgets then return end
    local theme = ctx.config.theme
    local statusColor = bridgeReady() and theme.green or theme.amber
    if state.status == "ERROR" then statusColor = theme.red end
    objectCall(widgets.status, "setContent", state.status)
    objectCall(widgets.status, "setColor", statusColor)

    local hasRows = #state.rows > 0
    local emptyText = state.statusDetail
        or (bridgeReady() and "Storage is empty" or "No bridge connection")
    objectCall(widgets.empty, "setContent", hasRows and "" or util.short(emptyText, 46))
    objectCall(widgets.empty, "setColor",
        state.status == "UPDATE BRIDGE" and theme.amber or theme.gray)

    for visibleIndex, entry in ipairs(widgets.rows) do
        local index = state.offset + visibleIndex - 1
        local item = state.rows[index]
        if item then
            local opacity = index == state.selected and 0.20
                or (index % 2 == 0 and 0.07 or 0)
            objectCall(entry.background, "setColor",
                index == state.selected and theme.purple or theme.blue)
            objectCall(entry.background, "setOpacity", opacity)
            objectCall(entry.label, "setContent", util.short(util.itemLabel(item), 28))
            objectCall(entry.label, "setColor", theme.white)
            objectCall(entry.count, "setContent", tostring(item.count or 0))
            objectCall(entry.count, "setColor", item.craftable and theme.purple or theme.blue)
        else
            objectCall(entry.background, "setOpacity", 0)
            objectCall(entry.label, "setContent", "")
            objectCall(entry.count, "setContent", "")
        end
    end
end

local function drawPanel(ctx)
    ctx.ui.clear()
    state.widgets = nil
    if not state.panelOpen or state.drawAt then return end
    local width, height = ctx.system.getSize()
    local theme = ctx.config.theme
    local panelW, panelH = math.min(270, width - 30), math.min(176, height - 30)
    local x, y = (width - panelW) / 2, (height - panelH) / 2
    local widgets = { rows = {} }
    state.widgets = widgets

    ctx.ui.textureRect(x, y, panelW, panelH, theme.background, 0.90, 70)
    ctx.ui.rectangle(x, y, panelW, 2, theme.purple, 1, 72)
    ctx.ui.rectangle(x, y + panelH - 2, panelW, 2, theme.blue, 1, 72)
    ctx.ui.text(x + 9, y + 7, "DIRECT STORAGE", theme.white, 1.05, 75)
    widgets.status = ctx.ui.text(x + panelW - 87, y + 8, state.status,
        theme.gray, 0.75, 75)

    local maxRows = math.min(ctx.config.storage.maxRows, math.floor((panelH - 50) / 14))
    widgets.empty = ctx.ui.text(x + 10, y + 35, "", theme.gray, 0.78, 75)
    for visibleIndex = 1, maxRows do
        local rowY = y + 27 + (visibleIndex - 1) * 14
        widgets.rows[visibleIndex] = {
            background = ctx.ui.rectangle(x + 7, rowY - 2, panelW - 14, 13,
                theme.blue, 0, 72),
            label = ctx.ui.text(x + 10, rowY, "", theme.white, 0.82, 75),
            count = ctx.ui.text(x + panelW - 54, rowY, "", theme.blue, 0.82, 75)
        }
    end
    ctx.ui.text(x + 9, y + panelH - 18,
        "L:take  R:stack  M:put hand  C:craft", theme.gray, 0.67, 75)
    updatePanel(ctx)
end

local function refreshPanel(ctx)
    if state.widgets then updatePanel(ctx)
    elseif state.panelOpen and not state.drawAt then drawPanel(ctx) end
end

local function refresh(ctx, query)
    if not state.serverId then
        state.status = "SEARCHING"
        refreshPanel(ctx)
        discover(ctx)
        return
    end
    if not bridgeReady() then
        state.status = "UPDATE BRIDGE"
        state.statusDetail = "Old bridge found; update and restart it"
        refreshPanel(ctx)
        return
    end
    state.status = "SYNC"
    state.statusDetail = "Reading connected inventories..."
    refreshPanel(ctx)
    send(ctx, "stock", { query = query or "", limit = 128 }, function(ok, data, err)
        if ok then
            state.rows = sortedStock(data and data.items)
            state.selected = math.max(1, math.min(state.selected, #state.rows))
            state.offset = math.max(1, math.min(state.offset, state.selected))
            state.status = "ONLINE"
            state.statusDetail = #state.rows == 0 and "Storage is empty" or nil
        else
            state.status = "ERROR"
            state.statusDetail = tostring(err)
            ctx.notify("Storage: " .. tostring(err), ctx.config.theme.red)
        end
        refreshPanel(ctx)
    end)
end

local function togglePanel(ctx)
    state.panelOpen = not state.panelOpen
    ctx.system.setInputMode(state.panelOpen and "storage" or nil)
    ctx.ui.clear()
    state.widgets = nil
    state.drawAt = nil
    if state.panelOpen then
        -- KeyboardScreen reports its final GUI size a few ticks after opening.
        -- Delay the first build so the panel never flashes at the old origin.
        state.drawAt = util.epoch()
            + (ctx.system.getModule("keyboard") and PANEL_SETTLE_MS or 0)
        if state.drawAt <= util.epoch() then
            state.drawAt = nil
            drawPanel(ctx)
        end
        refresh(ctx)
    end
end

function app.start(ctx)
    state.serverId = ctx.config.storage.serverId
    state.serverVersion = nil
    state.legacyServerId = nil
    state.pending = {}
    state.drawAt = nil
    state.widgets = nil
    ctx.services.provide("storage", {
        discover = function() return discover(ctx) end,
        status = function()
            return {
                online = bridgeReady(), serverId = state.serverId,
                version = state.serverVersion, status = state.status
            }
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
        keepInput = true,
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
    refreshPanel(ctx)
    send(ctx, operation, { name = item.name, count = count }, function(ok, data, err)
        if ok then
            state.status = "ONLINE"
            ctx.notify(("Storage %s: %s"):format(operation,
                textutils.serialize(data or {})), ctx.config.theme.green)
            refresh(ctx)
        else
            state.status = "ERROR"
            ctx.notify("Storage: " .. tostring(err), ctx.config.theme.red)
            refreshPanel(ctx)
        end
    end)
end

function app.onEvent(ctx, event, sender, message, protocol)
    if state.panelOpen then
        if event == "player_mouse_scroll" then
            local direction = tonumber(sender) or 1
            state.selected = math.max(1, math.min(#state.rows,
                state.selected + (direction > 0 and 1 or -1)))
            local page = state.widgets and #state.widgets.rows
                or ctx.config.storage.maxRows
            if state.selected < state.offset then state.offset = state.selected end
            if state.selected >= state.offset + page then
                state.offset = state.selected - page + 1
            end
            refreshPanel(ctx)
            return true
        elseif event == "player_mouse_click" then
            -- AP reports mouse buttons as 1=left, 2=right, 3=middle.
            local button = tonumber(sender) or 1
            if button == 3 then
                send(ctx, "deposit", { hand = true, count = 64 }, function(ok, data, err)
                    ctx.notify(ok and ("Deposited " .. tostring(data and data.moved or 0))
                        or ("Deposit: " .. tostring(err)),
                        ok and ctx.config.theme.green or ctx.config.theme.red)
                    refresh(ctx)
                end)
            else
                transfer(ctx, "withdraw", button == 2 and 64 or 1)
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
        elseif event == "keyboard_close"
                or (event == "glasses_key_pressed" and not ctx.system.getModule("keyboard")) then
            togglePanel(ctx)
            return true
        end
    end

    if event ~= "rednet_message" or protocol ~= ctx.config.storage.protocol
            or type(message) ~= "table" then return end
    if message.kind == "hello" and message.key == ctx.config.storage.sharedKey then
        if ctx.config.storage.serverId and sender ~= ctx.config.storage.serverId then return end
        local version = tonumber(message.version) or 0
        if version >= MIN_BRIDGE_VERSION then
            -- A late reply from an obsolete bridge must never replace a
            -- compatible one. This matters on servers where an old bridge
            -- computer was left running somewhere in loaded chunks.
            state.serverId = sender
            state.serverVersion = version
            state.status = "ONLINE"
            state.statusDetail = nil
            if state.panelOpen then refresh(ctx) end
        elseif not bridgeReady() then
            state.legacyServerId = sender
            state.serverId = nil
            state.serverVersion = nil
            state.status = "UPDATE BRIDGE"
            state.statusDetail = "Old bridge #" .. tostring(sender)
                .. " found; update and restart it"
            if state.panelOpen then refreshPanel(ctx) end
        end
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
    if state.panelOpen and state.drawAt and now >= state.drawAt then
        state.drawAt = nil
        drawPanel(ctx)
    end
    for id, pending in pairs(state.pending) do
        if now - pending.started > 50000 then
            state.pending[id] = nil
            if pending.callback then pending.callback(false, nil, "request timeout") end
        end
    end
end

function app.resize(ctx)
    if not state.panelOpen then return end
    ctx.ui.clear()
    state.widgets = nil
    -- Coalesce the resize burst emitted by KeyboardScreen and rebuild once at
    -- its final dimensions, matching the radial menu behaviour.
    state.drawAt = util.epoch() + PANEL_SETTLE_MS
end

function app.stop(ctx)
    if ctx.system.getInputMode() == "storage" then ctx.system.setInputMode(nil) end
    ctx.ui.clear()
    state.panelOpen = false
    state.drawAt = nil
    state.widgets = nil
end

api.registerApp(app)
return app
