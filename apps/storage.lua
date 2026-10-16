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
local DEFAULT_GRID_COLUMNS = 8
local DEFAULT_GRID_ROWS = 4
local SLOT_SIZE = 28
local SEARCH_DELAY_MS = 300
local STORAGE_MUTED = 0x344252

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
    widgets = nil,
    pointerX = nil,
    pointerY = nil,
    query = "",
    appliedQuery = "",
    searchActive = false,
    searchAt = nil,
    ignoreNextChar = false,
    stockGeneration = 0
}

local function objectCall(object, method, ...)
    if not object or type(object[method]) ~= "function" then return false end
    return pcall(object[method], ...)
end

local function setCached(holder, key, object, method, value)
    if holder[key] == value then return end
    holder[key] = value
    objectCall(object, method, value)
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

local function compactCount(value)
    value = tonumber(value) or 0
    if value >= 1000000 then
        local scaled = value / 1000000
        return (scaled >= 10 and ("%.0fM") or ("%.1fM")):format(scaled)
    end
    if value >= 1000 then
        local scaled = value / 1000
        return (scaled >= 10 and ("%.0fK") or ("%.1fK")):format(scaled)
    end
    return tostring(value)
end

local function ensureVisible(pageSize)
    if #state.rows == 0 then
        state.selected, state.offset = 1, 1
        return
    end
    state.selected = math.max(1, math.min(state.selected, #state.rows))
    pageSize = math.max(1, pageSize or 1)
    state.offset = math.floor((state.selected - 1) / pageSize) * pageSize + 1
end

local function positionPointerAtSelected()
    local widgets = state.widgets
    if not widgets then return end
    ensureVisible(widgets.pageSize)
    local visibleIndex = state.selected - state.offset + 1
    if visibleIndex < 1 or visibleIndex > widgets.pageSize then return end
    local column = (visibleIndex - 1) % widgets.columns
    local row = math.floor((visibleIndex - 1) / widgets.columns)
    state.pointerX = widgets.gridX + column * widgets.slotSize + widgets.slotSize / 2
    state.pointerY = widgets.gridY + row * widgets.slotSize + widgets.slotSize / 2
end

local function updatePanel(ctx)
    local widgets = state.widgets
    if not widgets then return end
    local theme = ctx.config.theme
    local statusColor = bridgeReady() and theme.green or theme.amber
    if state.status == "ERROR" then statusColor = theme.red end
    setCached(widgets, "statusText", widgets.status, "setContent", state.status)
    setCached(widgets, "statusColor", widgets.status, "setColor", statusColor)

    local hasRows = #state.rows > 0
    local emptyText = state.statusDetail
        or (bridgeReady() and "Storage is empty" or "No bridge connection")
    setCached(widgets, "emptyText", widgets.empty, "setContent",
        hasRows and "" or util.short(emptyText, 46))
    setCached(widgets, "emptyColor", widgets.empty, "setColor",
        state.status == "UPDATE BRIDGE" and theme.amber or theme.gray)

    ensureVisible(widgets.pageSize)
    local selectedItem = state.rows[state.selected]
    local totalPages = math.max(1, math.ceil(#state.rows / widgets.pageSize))
    local currentPage = math.floor((state.offset - 1) / widgets.pageSize) + 1
    local searchText
    if state.query ~= "" then
        searchText = (state.searchActive and "> " or "SEARCH: ") .. state.query
    else
        searchText = state.searchActive and "> " or "SEARCH... [F]"
    end
    setCached(widgets, "searchTextValue", widgets.searchText, "setContent", searchText)
    setCached(widgets, "searchTextColor", widgets.searchText, "setColor",
        state.searchActive and theme.white or theme.gray)
    setCached(widgets, "searchBackgroundColor", widgets.searchBackground, "setColor",
        state.searchActive and theme.purple or STORAGE_MUTED)
    setCached(widgets, "searchBackgroundOpacity", widgets.searchBackground,
        "setOpacity", state.searchActive and 0.48 or 0.24)
    setCached(widgets, "pageText", widgets.page, "setContent",
        ("%d/%d"):format(currentPage, totalPages))
    setCached(widgets, "selectedText", widgets.selectedLabel, "setContent",
        selectedItem and util.short(util.itemLabel(selectedItem), 34) or "")

    local trackHeight = widgets.gridRows * widgets.slotSize - 2
    local thumbHeight = math.max(12, trackHeight / totalPages)
    local thumbTravel = math.max(0, trackHeight - thumbHeight)
    local thumbTop = widgets.gridY + 1
        + (totalPages > 1 and (currentPage - 1) / (totalPages - 1) * thumbTravel or 0)
    if widgets.thumbHeight ~= thumbHeight then
        widgets.thumbHeight = thumbHeight
        objectCall(widgets.scrollThumb, "setSizes", 3, thumbHeight)
    end
    local thumbCenter = thumbTop + thumbHeight / 2
    if widgets.thumbCenter ~= thumbCenter then
        widgets.thumbCenter = thumbCenter
        objectCall(widgets.scrollThumb, "setPos", widgets.scrollX, thumbCenter, 79)
    end
    setCached(widgets, "scrollOpacity", widgets.scrollThumb, "setOpacity",
        totalPages > 1 and 0.95 or 0.32)

    for visibleIndex, entry in ipairs(widgets.rows) do
        local index = state.offset + visibleIndex - 1
        local item = state.rows[index]
        if item then
            local opacity = index == state.selected and 0.92 or 0.72
            setCached(entry, "backgroundColor", entry.background, "setColor",
                index == state.selected and theme.purple or STORAGE_MUTED)
            setCached(entry, "backgroundOpacity", entry.background, "setOpacity", opacity)
            if entry.item and entry.itemName ~= item.name then
                entry.itemName = item.name
                objectCall(entry.item, "setItem", item.name)
            end
            setCached(entry, "fallbackText", entry.fallback, "setContent",
                entry.item and "" or "?")
            setCached(entry, "countText", entry.count, "setContent",
                compactCount(item.count))
            setCached(entry, "countColor", entry.count, "setColor", theme.white)
        else
            setCached(entry, "backgroundOpacity", entry.background, "setOpacity", 0.36)
            if entry.item and entry.itemName ~= "" then
                entry.itemName = ""
                objectCall(entry.item, "setItem")
            end
            setCached(entry, "fallbackText", entry.fallback, "setContent", "")
            setCached(entry, "countText", entry.count, "setContent", "")
        end
    end

    if state.pointerX and state.pointerY then
        objectCall(widgets.cursorGlow, "setPos", state.pointerX, state.pointerY, 96)
        objectCall(widgets.cursorRing, "setPos", state.pointerX, state.pointerY, 97)
        objectCall(widgets.cursorDot, "setPos", state.pointerX, state.pointerY, 98)
    end
end

local function drawPanel(ctx)
    ctx.ui.clear()
    state.widgets = nil
    if not state.panelOpen or state.drawAt then return end
    local width, height = ctx.system.getSize()
    local theme = ctx.config.theme
    local panelW, panelH = math.min(292, width - 30), math.min(204, height - 30)
    local x, y = (width - panelW) / 2, (height - panelH) / 2
    local columns = math.max(1, math.min(
        ctx.config.storage.gridColumns or DEFAULT_GRID_COLUMNS,
        math.floor((panelW - 18) / SLOT_SIZE)))
    local gridRows = math.max(1, math.min(
        ctx.config.storage.gridRows or DEFAULT_GRID_ROWS,
        math.floor((panelH - 84) / SLOT_SIZE)))
    local gridW = columns * SLOT_SIZE
    local gridX, gridY = x + (panelW - gridW) / 2 - 3, y + 43
    local scrollX = gridX + gridW + 7
    local widgets = {
        rows = {}, columns = columns, gridRows = gridRows,
        pageSize = columns * gridRows, slotSize = SLOT_SIZE,
        gridX = gridX, gridY = gridY, scrollX = scrollX,
        searchX = gridX, searchY = y + 22, searchW = gridW, searchH = 15,
        scrollY = gridY + 1, scrollH = gridRows * SLOT_SIZE - 2,
        panelX = x, panelY = y, panelW = panelW, panelH = panelH
    }
    state.widgets = widgets

    -- A Rectangle is reliably opaque in AP 0.8.2a. Texture-based solid fills
    -- can still blend with the world even at opacity=1 on some render paths.
    ctx.ui.rectangle(x, y, panelW, panelH, theme.background, 1, 70)
    ctx.ui.rectangle(x, y, panelW, 2, theme.purple, 1, 72)
    ctx.ui.rectangle(x, y + panelH - 2, panelW, 2, STORAGE_MUTED, 1, 72)
    ctx.ui.text(x + 9, y + 7, "M2OS STORAGE", theme.white, 1.05, 75)
    widgets.status = ctx.ui.text(x + panelW - 87, y + 8, state.status,
        theme.gray, 0.75, 75)
    widgets.searchBackground = ctx.ui.rectangle(
        gridX, y + 22, gridW, 15, STORAGE_MUTED, 0.52, 73)
    widgets.searchText = ctx.ui.text(
        gridX + 5, y + 25, "SEARCH... [F]", theme.gray, 0.66, 76)
    widgets.page = ctx.ui.text(x + panelW - 37, y + 26, "1/1", theme.gray, 0.65, 76)
    widgets.empty = ctx.ui.text(x + 10, y + 47, "", theme.gray, 0.78, 83)
    for visibleIndex = 1, widgets.pageSize do
        local column = (visibleIndex - 1) % columns
        local row = math.floor((visibleIndex - 1) / columns)
        local slotX = gridX + column * SLOT_SIZE + 1
        local slotY = gridY + row * SLOT_SIZE + 1
        local iconX = slotX + (SLOT_SIZE - 2) / 2
        local iconY = slotY + (SLOT_SIZE - 2) / 2
        local okItem, itemObject = pcall(ctx.ui.raw, "Item", {
            gui = true, x = iconX, y = iconY, z = 78
        })
        widgets.rows[visibleIndex] = {
            background = ctx.ui.rectangle(slotX, slotY, SLOT_SIZE - 2, SLOT_SIZE - 2,
                STORAGE_MUTED, 0.72, 73),
            item = okItem and itemObject or nil,
            fallback = not okItem and ctx.ui.text(
                iconX - 3, iconY - 5, "", theme.gray, 0.9, 79) or nil,
            count = ctx.ui.text(slotX + SLOT_SIZE - 13, slotY + SLOT_SIZE - 10,
                "", theme.white, 0.58, 82)
        }
    end
    widgets.scrollTrack = ctx.ui.rectangle(scrollX - 1.5, gridY + 1,
        3, gridRows * SLOT_SIZE - 2, theme.gray, 0.22, 75)
    widgets.scrollThumb = ctx.ui.rectangle(scrollX - 1.5, gridY + 1,
        3, 12, theme.purple, 0.95, 79)
    widgets.selectedLabel = ctx.ui.text(x + 9, y + panelH - 31,
        "", theme.white, 0.72, 84)
    ctx.ui.text(x + 9, y + panelH - 16,
        "L:take R:stack M/P:deposit C:craft", theme.gray, 0.60, 75)
    widgets.cursorGlow = ctx.ui.raw("Circle", {
        gui = true, x = gridX, y = gridY, z = 96, radius = 7,
        filled = true, color = theme.purple, opacity = 0.16
    })
    widgets.cursorRing = ctx.ui.raw("Circle", {
        gui = true, x = gridX, y = gridY, z = 97, radius = 4.5,
        filled = false, borderWidth = 1.2, color = theme.white, opacity = 1
    })
    widgets.cursorDot = ctx.ui.raw("Circle", {
        gui = true, x = gridX, y = gridY, z = 98, radius = 1.5,
        filled = true, color = theme.purple, opacity = 1
    })
    if not state.pointerX or not state.pointerY then positionPointerAtSelected() end
    updatePanel(ctx)
end

local function refreshPanel(ctx)
    if state.widgets then updatePanel(ctx)
    elseif state.panelOpen and not state.drawAt then drawPanel(ctx) end
end

local function refresh(ctx, query)
    query = tostring(query == nil and state.query or query)
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
    state.stockGeneration = state.stockGeneration + 1
    local generation = state.stockGeneration
    send(ctx, "stock", { query = query, limit = 128 }, function(ok, data, err)
        if generation ~= state.stockGeneration then return end
        if ok then
            state.rows = sortedStock(data and data.items)
            if state.appliedQuery ~= query then
                state.selected, state.offset = 1, 1
            else
                state.selected = math.max(1, math.min(state.selected, #state.rows))
                state.offset = math.max(1, math.min(state.offset, state.selected))
            end
            state.appliedQuery = query
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
        state.pointerX, state.pointerY = nil, nil
        state.searchActive = false
        state.ignoreNextChar = false
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

local function depositHand(ctx)
    send(ctx, "deposit", { hand = true, count = 64 }, function(ok, data, err)
        ctx.notify(ok and ("Deposited " .. tostring(data and data.moved or 0))
            or ("Deposit: " .. tostring(err)),
            ok and ctx.config.theme.green or ctx.config.theme.red)
        refresh(ctx)
    end)
end

local function movePointer(ctx, dx, dy)
    local widgets = state.widgets
    if not widgets then return end
    state.pointerX = util.clamp((state.pointerX or widgets.gridX) + dx,
        widgets.panelX + 3, widgets.panelX + widgets.panelW - 3)
    state.pointerY = util.clamp((state.pointerY or widgets.gridY) + dy,
        widgets.panelY + 3, widgets.panelY + widgets.panelH - 3)

    local relativeX = state.pointerX - widgets.gridX
    local relativeY = state.pointerY - widgets.gridY
    local gridWidth = widgets.columns * widgets.slotSize
    local gridHeight = widgets.gridRows * widgets.slotSize
    if relativeX >= 0 and relativeX < gridWidth
            and relativeY >= 0 and relativeY < gridHeight then
        local column = math.floor(relativeX / widgets.slotSize)
        local row = math.floor(relativeY / widgets.slotSize)
        local index = state.offset + row * widgets.columns + column
        if state.rows[index] then state.selected = index end
    end
    updatePanel(ctx)
end

local function numericArguments(...)
    local out = {}
    for _, value in ipairs({ ... }) do
        if type(value) == "number" then out[#out + 1] = value end
    end
    return out
end

local function pointerInside(x, y, width, height)
    return state.pointerX and state.pointerY
        and state.pointerX >= x and state.pointerX < x + width
        and state.pointerY >= y and state.pointerY < y + height
end

local function selectPage(ctx, requestedPage)
    local widgets = state.widgets
    if not widgets or #state.rows == 0 then return end
    local totalPages = math.max(1, math.ceil(#state.rows / widgets.pageSize))
    local page = util.clamp(math.floor(requestedPage), 1, totalPages)
    local visibleIndex = util.clamp(state.selected - state.offset, 0,
        widgets.pageSize - 1)
    state.offset = (page - 1) * widgets.pageSize + 1
    state.selected = math.min(#state.rows, state.offset + visibleIndex)

    if pointerInside(widgets.gridX, widgets.gridY,
            widgets.columns * widgets.slotSize,
            widgets.gridRows * widgets.slotSize) then
        local column = math.floor((state.pointerX - widgets.gridX) / widgets.slotSize)
        local row = math.floor((state.pointerY - widgets.gridY) / widgets.slotSize)
        local pointed = state.offset + row * widgets.columns + column
        if state.rows[pointed] then state.selected = pointed end
    end
    updatePanel(ctx)
end

local function scheduleSearch(ctx)
    state.searchAt = util.epoch() + SEARCH_DELAY_MS
    state.status = "SEARCH"
    refreshPanel(ctx)
end

function app.onEvent(ctx, event, sender, message, protocol)
    if state.panelOpen then
        if event == "char" and state.searchActive then
            if state.ignoreNextChar then
                state.ignoreNextChar = false
            else
                local character = tostring(sender or "")
                if #state.query < 48 and #character > 0 then
                    state.query = state.query .. character
                    scheduleSearch(ctx)
                end
            end
            return true
        elseif event == "player_mouse_move" then
            local values = numericArguments(sender, message, protocol)
            local dx = values[#values - 1] or 0
            local dy = values[#values] or 0
            movePointer(ctx, dx, dy)
            return true
        elseif event == "player_mouse_scroll" then
            local direction = tonumber(sender) or 1
            local currentPage = state.widgets
                and math.floor((state.offset - 1) / state.widgets.pageSize) + 1 or 1
            selectPage(ctx, currentPage + (direction > 0 and 1 or -1))
            return true
        elseif event == "player_mouse_click" then
            -- AP reports mouse buttons as 1=left, 2=right, 3=middle.
            local button = tonumber(sender) or 1
            local widgets = state.widgets
            if widgets and button == 1
                    and pointerInside(widgets.searchX, widgets.searchY,
                    widgets.searchW, widgets.searchH) then
                state.searchActive = true
                state.ignoreNextChar = false
                refreshPanel(ctx)
                return true
            end
            if widgets and button == 1
                    and pointerInside(widgets.scrollX - 5, widgets.scrollY,
                        10, widgets.scrollH) then
                local totalPages = math.max(1,
                    math.ceil(#state.rows / widgets.pageSize))
                local ratio = util.clamp(
                    (state.pointerY - widgets.scrollY) / widgets.scrollH, 0, 0.999)
                selectPage(ctx, math.floor(ratio * totalPages) + 1)
                return true
            end
            if button == 3 then
                state.searchActive = false
                refreshPanel(ctx)
                depositHand(ctx)
                return true
            end
            if not widgets or not pointerInside(widgets.gridX, widgets.gridY,
                    widgets.columns * widgets.slotSize,
                    widgets.gridRows * widgets.slotSize) then return true end
            state.searchActive = false
            refreshPanel(ctx)
            transfer(ctx, "withdraw", button == 2 and 64 or 1)
            return true
        elseif event == "key" and keys then
            local code = tonumber(sender)
            if state.searchActive then
                if code == keys.backspace then
                    state.query = state.query:sub(1, math.max(0, #state.query - 1))
                    scheduleSearch(ctx)
                elseif code == keys.delete then
                    state.query = ""
                    scheduleSearch(ctx)
                elseif code == keys.enter or code == keys.numPadEnter then
                    state.searchActive = false
                    state.searchAt = nil
                    refresh(ctx, state.query)
                elseif code == keys.escape then
                    state.searchActive = false
                    state.ignoreNextChar = false
                    refreshPanel(ctx)
                end
                return true
            end
            if code == keys.f then
                state.searchActive = true
                state.ignoreNextChar = true
                refreshPanel(ctx)
                return true
            end
            if code == keys.c then transfer(ctx, "craft", 1) return true end
            if code == keys.q then transfer(ctx, "withdraw", 64) return true end
            if code == keys.enter or code == keys.numPadEnter then
                transfer(ctx, "withdraw", 1) return true
            end
            if code == keys.p then
                depositHand(ctx)
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
    if state.panelOpen and state.searchAt and now >= state.searchAt then
        state.searchAt = nil
        refresh(ctx, state.query)
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
    state.pointerX, state.pointerY = nil, nil
    -- Coalesce the resize burst emitted by KeyboardScreen and rebuild once at
    -- its final dimensions, matching the radial menu behaviour.
    state.drawAt = util.epoch() + PANEL_SETTLE_MS
end

function app.stop(ctx)
    if ctx.system.getInputMode() == "storage" then ctx.system.setInputMode(nil) end
    ctx.ui.clear()
    state.panelOpen = false
    state.searchActive = false
    state.searchAt = nil
    state.drawAt = nil
    state.widgets = nil
end

api.registerApp(app)
return app
