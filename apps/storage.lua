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

local MIN_BRIDGE_VERSION = 4
local PANEL_SETTLE_MS = 180
local DEFAULT_GRID_COLUMNS = 8
local DEFAULT_GRID_ROWS = 4
local SLOT_SIZE = 28
local INVENTORY_COLUMNS = 9
local INVENTORY_ROWS = 4
local INVENTORY_SLOT_SIZE = 24
local CURSOR_FLUSH_INTERVAL_MS = 25
local SEARCH_DELAY_MS = 300
local STORAGE_MUTED = 0x344252
local QUEUE_VISIBLE_ROWS = 9
local QUEUE_HISTORY_LIMIT = 18
local QUEUE_RESULT_LIFETIME_MS = 6000

local state = {
    modemName = nil,
    serverId = nil,
    serverVersion = nil,
    pending = {},
    sequence = 0,
    panelOpen = false,
    rows = {},
    playerSlots = {},
    playerCapacity = 0,
    selectedPlayerSlot = nil,
    view = "storage",
    status = "OFFLINE",
    statusDetail = nil,
    legacyServerId = nil,
    selected = 1,
    offset = 1,
    drawAt = nil,
    widgets = nil,
    pointerX = nil,
    pointerY = nil,
    pointerDirty = false,
    lastPointerFlush = 0,
    hoveredQueueSlot = nil,
    query = "",
    appliedQuery = "",
    searchActive = false,
    searchAt = nil,
    ignoreNextChar = false,
    stockGeneration = 0,
    inventoryGeneration = 0,
    transferQueue = {},
    transferSequence = 0,
    transferBusy = false
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
    state.pending[id] = {
        callback = callback, started = util.epoch(), operation = operation
    }
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

-- Inventory Manager numbers the hotbar as slots 1..9. Display it on the last
-- row, matching the familiar Minecraft inventory layout.
local function playerSlotForCell(cell)
    if cell <= 27 then return cell + 9 end
    return cell - 27
end

local function readableItemLabel(item)
    if not item then return "" end
    local label = util.itemLabel(item)
    -- The bundled glasses font renders many localized glyphs as question
    -- marks. Registry paths are ASCII and remain readable for every item.
    if label:find("[\128-\255]") then
        label = tostring(item.name or "item"):gsub("^.+:", ""):gsub("_", " ")
    end
    return label
end

local function queueOperation(operation, item, count, payload, callback)
    state.transferSequence = state.transferSequence + 1
    local entry = {
        id = state.transferSequence,
        operation = operation,
        name = item and item.name or nil,
        label = item and readableItemLabel(item) or "held stack",
        requested = math.max(1, tonumber(count) or 1),
        status = "queued",
        started = util.epoch(),
        payload = payload,
        callback = callback
    }
    state.transferQueue[#state.transferQueue + 1] = entry

    while #state.transferQueue > QUEUE_HISTORY_LIMIT do
        local removed = false
        for index = 1, #state.transferQueue do
            local status = state.transferQueue[index].status
            if status ~= "pending" and status ~= "queued" then
                table.remove(state.transferQueue, index)
                removed = true
                break
            end
        end
        if not removed then break end
    end
    return entry
end

local function finishQueueOperation(entry, ok, data, err)
    if not entry then return end
    entry.finished = util.epoch()
    entry.expires = entry.finished + QUEUE_RESULT_LIFETIME_MS
    entry.moved = tonumber(data and data.moved) or 0
    entry.error = err and tostring(err) or nil
    local requested = tonumber(data and data.requested) or entry.requested
    local remaining = tonumber(data and data.remaining) or 0
    entry.requested = requested
    if not ok then
        entry.status = "failed"
    elseif remaining > 0 or entry.moved < requested then
        entry.status = "partial"
    else
        entry.status = "done"
    end
end

local function queueDetail(entry)
    local action = entry.operation == "withdraw" and "GET"
        or entry.operation == "deposit" and "PUT"
        or entry.operation == "craft" and "MAKE" or "DO"
    if entry.status == "queued" then
        return ("%s x%d  NEXT"):format(action, entry.requested)
    end
    if entry.status == "pending" then
        return ("%s x%d  WAIT"):format(action, entry.requested)
    end
    if entry.status == "partial" then
        return ("%s %d/%d PART"):format(action, entry.moved or 0, entry.requested)
    end
    if entry.status == "failed" then
        return ("%s x%d  FAIL"):format(action, entry.requested)
    end
    return ("%s x%d  DONE"):format(action, entry.moved or entry.requested)
end

local function visibleQueueEntries()
    local visible = {}
    for _, entry in ipairs(state.transferQueue) do
        if entry.status == "queued" or entry.status == "pending" then
            visible[#visible + 1] = entry
            if #visible >= QUEUE_VISIBLE_ROWS then return visible end
        end
    end
    for index = #state.transferQueue, 1, -1 do
        local entry = state.transferQueue[index]
        if entry.status ~= "queued" and entry.status ~= "pending" then
            visible[#visible + 1] = entry
            if #visible >= QUEUE_VISIBLE_ROWS then break end
        end
    end
    return visible
end

local processTransferQueue

local function pruneTransferQueue(now)
    local changed = false
    for index = #state.transferQueue, 1, -1 do
        local entry = state.transferQueue[index]
        if entry.expires and now >= entry.expires then
            table.remove(state.transferQueue, index)
            changed = true
        end
    end
    return changed
end

local function setCellGeometry(entry, x, y, size)
    local key = ("%.2f:%.2f:%d"):format(x, y, size)
    if entry.geometryKey == key then return end
    entry.geometryKey = key
    local contentSize = size - 2
    local centerX, centerY = x + contentSize / 2, y + contentSize / 2
    objectCall(entry.background, "setPos", centerX, centerY, 74)
    objectCall(entry.background, "setSizes", contentSize, contentSize)
    objectCall(entry.item, "setPos", centerX, centerY, 80)
    objectCall(entry.fallback, "setPos", centerX - 3, centerY - 5, 81)
    objectCall(entry.count, "setPos", x + size - 11, y + size - 8, 83)
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

    local storageView = state.view == "storage"
    local visibleQueue = visibleQueueEntries()
    local hasRows = storageView and #state.rows > 0
        or (not storageView and next(state.playerSlots) ~= nil)
    local emptyText = state.statusDetail
        or (bridgeReady() and (storageView and "Storage is empty"
            or "Player inventory is empty") or "No bridge connection")
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
    setCached(widgets, "searchTextValue", widgets.searchText, "setContent",
        storageView and searchText or "CLICK A STACK TO DEPOSIT IT")
    setCached(widgets, "searchTextColor", widgets.searchText, "setColor",
        storageView and state.searchActive and theme.white or theme.gray)
    setCached(widgets, "searchBackgroundColor", widgets.searchBackground, "setColor",
        storageView and state.searchActive and theme.purple or STORAGE_MUTED)
    setCached(widgets, "searchBackgroundOpacity", widgets.searchBackground,
        "setOpacity", storageView and (state.searchActive and 0.48 or 0.24) or 0.34)
    setCached(widgets, "pageText", widgets.page, "setContent",
        storageView and ("%d/%d"):format(currentPage, totalPages) or "")
    local selectedPlayer = state.selectedPlayerSlot
        and state.playerSlots[state.selectedPlayerSlot] or nil
    local labelItem = storageView and selectedItem or nil
    if not storageView then labelItem = selectedPlayer end
    local hoveredQueued = state.hoveredQueueSlot
        and visibleQueue[state.hoveredQueueSlot] or nil
    setCached(widgets, "selectedText", widgets.selectedLabel, "setContent",
        hoveredQueued and util.short(
            hoveredQueued.label .. "  " .. queueDetail(hoveredQueued), 50)
            or util.short(readableItemLabel(labelItem), 34))
    setCached(widgets, "storageTabColor", widgets.storageTab, "setColor",
        storageView and theme.white or theme.gray)
    setCached(widgets, "inventoryTabColor", widgets.inventoryTab, "setColor",
        storageView and theme.gray or theme.white)
    local tabMarkerX = storageView and widgets.storageTabCenter
        or widgets.inventoryTabCenter
    if widgets.tabMarkerX ~= tabMarkerX then
        widgets.tabMarkerX = tabMarkerX
        objectCall(widgets.tabMarker, "setPos", tabMarkerX, widgets.panelY + 19, 77)
    end
    setCached(widgets, "footerText", widgets.footer, "setContent",
        storageView and "L:take  R:stack  I:inventory"
            or "CLICK: DEPOSIT FULL STACK  I:storage")

    if widgets.queueRows then
        local hidden = math.max(0, #state.transferQueue - #visibleQueue)
        local waiting = 0
        for _, queued in ipairs(state.transferQueue) do
            if queued.status == "queued" or queued.status == "pending" then
                waiting = waiting + 1
            end
        end
        setCached(widgets, "queueTitleText", widgets.queueTitle, "setContent",
            ("REQUEST QUEUE  %d%s"):format(waiting,
                hidden > 0 and ("  +" .. hidden) or ""))
        for index, row in ipairs(widgets.queueRows) do
            local queued = visibleQueue[index]
            if queued then
                local queueColor = queued.status == "failed" and theme.red
                    or queued.status == "done" and theme.green
                    or theme.amber
                setCached(row, "backgroundColor", row.background, "setColor", queueColor)
                setCached(row, "backgroundOpacity", row.background, "setOpacity",
                    (queued.status == "pending" or queued.status == "queued")
                        and 0.42 or 0.24)
                local shownCount = queued.status == "partial" and queued.moved
                    or queued.status == "done" and queued.moved
                    or queued.requested
                setCached(row, "countText", row.count, "setContent",
                    compactCount(shownCount))
                setCached(row, "stateText", row.state, "setContent",
                    queued.status == "pending" and "W"
                        or queued.status == "queued" and ">"
                        or queued.status == "done" and "+"
                        or queued.status == "partial" and "~" or "!")
                setCached(row, "stateColor", row.state, "setColor", queueColor)
                if row.item and row.itemName ~= queued.name then
                    row.itemName = queued.name
                    objectCall(row.item, "setItem", queued.name)
                end
                setCached(row, "fallbackText", row.fallback, "setContent",
                    row.item and "" or "?")
            else
                setCached(row, "backgroundOpacity", row.background, "setOpacity", 0.12)
                setCached(row, "countText", row.count, "setContent", "")
                setCached(row, "stateText", row.state, "setContent", "")
                setCached(row, "fallbackText", row.fallback, "setContent", "")
                if row.item and row.itemName ~= "" then
                    row.itemName = ""
                    objectCall(row.item, "setItem")
                end
            end
        end
    elseif state.transferQueue[1] then
        local queued = visibleQueue[1]
        setCached(widgets, "selectedText", widgets.selectedLabel, "setContent",
            util.short("QUEUE: " .. queueDetail(queued) .. " " .. queued.label, 50))
    end

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
        storageView and (totalPages > 1 and 0.95 or 0.32) or 0)
    setCached(widgets, "scrollTrackOpacity", widgets.scrollTrack, "setOpacity",
        storageView and 0.22 or 0)

    for cell, entry in ipairs(widgets.rows) do
        local item, selected, active, slotX, slotY, slotSize
        if storageView then
            active = cell <= widgets.pageSize
            local column = (cell - 1) % widgets.columns
            local row = math.floor((cell - 1) / widgets.columns)
            slotX = widgets.gridX + column * widgets.slotSize + 1
            slotY = widgets.gridY + row * widgets.slotSize + 1
            slotSize = widgets.slotSize
            local index = state.offset + cell - 1
            item = active and state.rows[index] or nil
            selected = index == state.selected
        else
            active = cell <= INVENTORY_COLUMNS * INVENTORY_ROWS
            local column = (cell - 1) % INVENTORY_COLUMNS
            local row = math.floor((cell - 1) / INVENTORY_COLUMNS)
            slotX = widgets.inventoryGridX + column * INVENTORY_SLOT_SIZE + 1
            slotY = widgets.inventoryGridY + row * INVENTORY_SLOT_SIZE + 1
            slotSize = INVENTORY_SLOT_SIZE
            local slot = playerSlotForCell(cell)
            item = active and state.playerSlots[slot] or nil
            selected = slot == state.selectedPlayerSlot
        end
        setCellGeometry(entry, slotX, slotY, slotSize)
        if active and item then
            setCached(entry, "backgroundColor", entry.background, "setColor",
                selected and theme.purple or STORAGE_MUTED)
            setCached(entry, "backgroundOpacity", entry.background, "setOpacity",
                selected and 0.92 or 0.72)
            if entry.item and entry.itemName ~= item.name then
                entry.itemName = item.name
                objectCall(entry.item, "setItem", item.name)
            end
            setCached(entry, "fallbackText", entry.fallback, "setContent",
                entry.item and "" or "?")
            setCached(entry, "countText", entry.count, "setContent",
                compactCount(item.count))
        else
            setCached(entry, "backgroundOpacity", entry.background, "setOpacity",
                active and (storageView and 0.36 or 0.30) or 0)
            if entry.item and entry.itemName ~= "" then
                entry.itemName = ""
                objectCall(entry.item, "setItem")
            end
            setCached(entry, "fallbackText", entry.fallback, "setContent", "")
            setCached(entry, "countText", entry.count, "setContent", "")
        end
    end

    if state.pointerX and state.pointerY then
        objectCall(widgets.cursorRing, "setPos", state.pointerX, state.pointerY, 97)
        state.pointerDirty = false
    end
end

local function drawPanel(ctx)
    ctx.ui.clear()
    state.widgets = nil
    if not state.panelOpen or state.drawAt then return end
    local width, height = ctx.system.getSize()
    local theme = ctx.config.theme
    local panelW, panelH = math.min(356, width - 30), math.min(232, height - 30)
    local x, y = (width - panelW) / 2, (height - panelH) / 2
    local columns = math.max(1, math.min(
        ctx.config.storage.gridColumns or DEFAULT_GRID_COLUMNS,
        math.floor((panelW - 18) / SLOT_SIZE)))
    local gridRows = math.max(1, math.min(
        ctx.config.storage.gridRows or DEFAULT_GRID_ROWS,
        math.floor((panelH - 84) / SLOT_SIZE)))
    local gridW = columns * SLOT_SIZE
    local showQueueBar = panelH >= 218
    local gridX = x + (panelW - gridW) / 2 - 3
    local gridY = y + 43
    local scrollX = gridX + gridW + 7
    local inventoryGridW = INVENTORY_COLUMNS * INVENTORY_SLOT_SIZE
    local inventoryGridH = INVENTORY_ROWS * INVENTORY_SLOT_SIZE
    local widgets = {
        rows = {}, columns = columns, gridRows = gridRows,
        pageSize = columns * gridRows, slotSize = SLOT_SIZE,
        gridX = gridX, gridY = gridY, scrollX = scrollX,
        inventoryGridX = gridX + (gridW - inventoryGridW) / 2,
        inventoryGridY = gridY + (gridRows * SLOT_SIZE - inventoryGridH) / 2,
        inventoryGridW = inventoryGridW, inventoryGridH = inventoryGridH,
        searchX = gridX, searchY = y + 22, searchW = gridW, searchH = 15,
        scrollY = gridY + 1, scrollH = gridRows * SLOT_SIZE - 2,
        panelX = x, panelY = y, panelW = panelW, panelH = panelH,
        storageTabX = x + 8, storageTabY = y + 4,
        storageTabW = 58, storageTabH = 17,
        inventoryTabX = x + 72, inventoryTabY = y + 4,
        inventoryTabW = 70, inventoryTabH = 17,
        storageTabCenter = x + 37, inventoryTabCenter = x + 107,
        showQueueBar = showQueueBar
    }
    state.widgets = widgets

    -- A Rectangle is reliably opaque in AP 0.8.2a. Texture-based solid fills
    -- can still blend with the world even at opacity=1 on some render paths.
    ctx.ui.rectangle(x, y, panelW, panelH, theme.background, 1, 70)
    ctx.ui.rectangle(x, y, panelW, 2, theme.purple, 1, 72)
    ctx.ui.rectangle(x, y + panelH - 2, panelW, 2, STORAGE_MUTED, 1, 72)
    widgets.storageTab = ctx.ui.text(x + 9, y + 7, "STORAGE", theme.white, 0.78, 75)
    widgets.inventoryTab = ctx.ui.text(x + 74, y + 7, "INVENTORY", theme.gray, 0.78, 75)
    widgets.tabMarker = ctx.ui.rectangle(
        widgets.storageTabCenter - 27, y + 18, 54, 2, theme.purple, 1, 77)
    widgets.status = ctx.ui.text(x + panelW - 70, y + 8, state.status,
        theme.gray, 0.75, 75)
    widgets.searchBackground = ctx.ui.rectangle(
        gridX, y + 22, gridW, 15, STORAGE_MUTED, 0.52, 73)
    widgets.searchText = ctx.ui.text(
        gridX + 5, y + 25, "SEARCH... [F]", theme.gray, 0.66, 76)
    widgets.page = ctx.ui.text(x + panelW - 37, y + 26, "1/1", theme.gray, 0.65, 76)
    widgets.empty = ctx.ui.text(x + 10, y + 47, "", theme.gray, 0.78, 83)
    widgets.cellCount = math.max(widgets.pageSize,
        INVENTORY_COLUMNS * INVENTORY_ROWS)
    for visibleIndex = 1, widgets.cellCount do
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
                STORAGE_MUTED, 0, 73),
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
    if showQueueBar then
        widgets.queueRows = {}
        local queueSlotSize = 24
        local queueWidth = QUEUE_VISIBLE_ROWS * queueSlotSize
        local queueX = x + (panelW - queueWidth) / 2
        local queueY = gridY + gridRows * SLOT_SIZE + 13
        widgets.queueX = queueX
        widgets.queueY = queueY
        widgets.queueSlotSize = queueSlotSize
        widgets.queueWidth = queueWidth
        widgets.queueTitle = ctx.ui.text(queueX, queueY - 10,
            "REQUEST QUEUE  0", theme.gray, 0.53, 80)
        for index = 1, QUEUE_VISIBLE_ROWS do
            local slotX = queueX + (index - 1) * queueSlotSize
            local okItem, itemObject = pcall(ctx.ui.raw, "Item", {
                gui = true, x = slotX + 11, y = queueY + 11, z = 82
            })
            widgets.queueRows[index] = {
                background = ctx.ui.rectangle(slotX, queueY,
                    queueSlotSize - 2, queueSlotSize - 2,
                    STORAGE_MUTED, 0.12, 76),
                item = okItem and itemObject or nil,
                fallback = not okItem and ctx.ui.text(
                    slotX + 8, queueY + 5, "", theme.gray, 0.8, 83) or nil,
                state = ctx.ui.text(slotX + 2, queueY + 2,
                    "", theme.gray, 0.48, 85),
                count = ctx.ui.text(slotX + queueSlotSize - 11,
                    queueY + queueSlotSize - 9, "", theme.white, 0.54, 85)
            }
        end
    end
    widgets.selectedLabel = ctx.ui.text(x + 9, y + panelH - 31,
        "", theme.white, 0.72, 84)
    widgets.footer = ctx.ui.text(x + 9, y + panelH - 16,
        "L:take  R:stack  I:inventory", theme.gray, 0.60, 75)
    widgets.cursorRing = ctx.ui.raw("Circle", {
        gui = true, x = gridX, y = gridY, z = 97, radius = 4.5,
        filled = false, borderWidth = 1.5, color = theme.white, opacity = 1
    })
    if not state.pointerX or not state.pointerY then positionPointerAtSelected() end
    updatePanel(ctx)
end

local function refreshPanel(ctx)
    if state.widgets then updatePanel(ctx)
    elseif state.panelOpen and not state.drawAt then drawPanel(ctx) end
end

local function refreshPlayerInventory(ctx)
    if not bridgeReady() then return end
    state.inventoryGeneration = state.inventoryGeneration + 1
    local generation = state.inventoryGeneration
    send(ctx, "player_inventory", {}, function(ok, data, err)
        if generation ~= state.inventoryGeneration then return end
        if ok then
            local slots = {}
            for _, item in pairs(type(data) == "table" and data.slots or {}) do
                local slot = tonumber(type(item) == "table" and item.slot)
                if slot and item.name then slots[slot] = item end
            end
            state.playerSlots = slots
            state.playerCapacity = tonumber(data and data.capacity) or 0
            if state.selectedPlayerSlot and not slots[state.selectedPlayerSlot] then
                state.selectedPlayerSlot = nil
            end
            if not state.selectedPlayerSlot then
                for slot = 1, INVENTORY_COLUMNS * INVENTORY_ROWS do
                    if slots[slot] then state.selectedPlayerSlot = slot break end
                end
            end
        elseif state.view == "inventory" then
            state.status = "ERROR"
            state.statusDetail = tostring(err)
            ctx.notify("Inventory: " .. tostring(err), ctx.config.theme.red)
        end
        refreshPanel(ctx)
    end)
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
    if state.view == "inventory" then refreshPlayerInventory(ctx) end
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
            state.statusDetail = nil
        else
            state.status = "ERROR"
            state.statusDetail = tostring(err)
            ctx.notify("Storage: " .. tostring(err), ctx.config.theme.red)
        end
        refreshPanel(ctx)
    end)
end

processTransferQueue = function(ctx)
    if state.transferBusy then return true end
    local queued
    for _, entry in ipairs(state.transferQueue) do
        if entry.status == "queued" then
            queued = entry
            break
        end
    end
    if not queued then return false end

    state.transferBusy = true
    queued.status = "pending"
    refreshPanel(ctx)
    send(ctx, queued.operation, queued.payload, function(ok, data, err)
        finishQueueOperation(queued, ok, data, err)
        if queued.callback then
            local callbackOk, callbackError = pcall(queued.callback, ok, data, err)
            if not callbackOk then
                queued.status = "failed"
                queued.error = tostring(callbackError)
                ctx.notify("Queue callback: " .. tostring(callbackError),
                    ctx.config.theme.red)
            end
        end
        queued.callback = nil
        queued.payload = nil
        state.transferBusy = false
        refreshPanel(ctx)
        if not processTransferQueue(ctx) then refresh(ctx) end
    end)
    return true
end

local function togglePanel(ctx)
    state.panelOpen = not state.panelOpen
    ctx.system.setInputMode(state.panelOpen and "storage" or nil)
    ctx.ui.clear()
    state.widgets = nil
    state.drawAt = nil
    if state.panelOpen then
        state.pointerX, state.pointerY = nil, nil
        state.pointerDirty = false
        state.lastPointerFlush = 0
        state.hoveredQueueSlot = nil
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
    state.hoveredQueueSlot = nil
    state.view = "storage"
    state.playerSlots = {}
    state.playerCapacity = 0
    state.selectedPlayerSlot = nil
    state.inventoryGeneration = 0
    state.transferQueue = {}
    state.transferSequence = 0
    state.transferBusy = false
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
        playerInventory = function(callback)
            return send(ctx, "player_inventory", {}, callback)
        end,
        depositSlot = function(slot, callback)
            return send(ctx, "deposit", { slot = slot }, callback)
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
    local requested = math.min(math.max(1, tonumber(count) or 1), item.count or 1)
    queueOperation(operation, item, requested,
        { name = item.name, count = requested }, function(ok, data, err)
        if ok then
            state.status = "ONLINE"
            local moved = tonumber(data and data.moved) or 0
            local remaining = tonumber(data and data.remaining) or 0
            if remaining > 0 then
                ctx.notify(("Inventory full: moved %d/%d"):format(
                    moved, tonumber(data and data.requested) or requested),
                    ctx.config.theme.amber)
            else
                ctx.notify(("Received %d item(s)"):format(moved),
                    ctx.config.theme.green)
            end
        else
            state.status = "ERROR"
            ctx.notify("Inventory full or transfer failed: " .. tostring(err),
                ctx.config.theme.red)
        end
    end)
    if operation == "withdraw" then
        state.stockGeneration = state.stockGeneration + 1
        item.count = math.max(0, (item.count or 0) - requested)
        if item.count == 0 then
            table.remove(state.rows, state.selected)
            state.selected = math.max(1, math.min(state.selected, #state.rows))
        end
    end
    state.status = operation == "craft" and "CRAFTING" or "DELIVERY"
    refreshPanel(ctx)
    processTransferQueue(ctx)
end

local function setView(ctx, view)
    if view ~= "storage" and view ~= "inventory" then return end
    state.view = view
    state.searchActive = false
    state.ignoreNextChar = false
    if view == "inventory" then refreshPlayerInventory(ctx) end
    refreshPanel(ctx)
end

local function depositPlayerSlot(ctx, slot)
    slot = tonumber(slot)
    local stack = slot and state.playerSlots[slot] or nil
    if not stack then return end
    local expectedName = stack.name
    local expectedCount = tonumber(stack.count) or 0
    queueOperation("deposit", stack, expectedCount,
        { slot = slot, name = expectedName }, function(ok, data, err)
        if ok then
            state.status = "ONLINE"
            local moved = tonumber(data and data.moved) or 0
            local requested = tonumber(data and data.requested) or expectedCount
            local remaining = tonumber(data and data.remaining) or 0
            if remaining > 0 then
                ctx.notify(("Storage full: moved %d/%d"):format(moved, requested),
                    ctx.config.theme.amber)
            else
                ctx.notify(("Deposited full stack: %d"):format(moved),
                    ctx.config.theme.green)
            end
        else
            state.status = "ERROR"
            ctx.notify("Storage full or item rejected: " .. tostring(err),
                ctx.config.theme.red)
        end
    end)

    -- Hide it immediately. The authoritative refresh below restores whatever
    -- remained when a storage accepted only part of the stack.
    state.inventoryGeneration = state.inventoryGeneration + 1
    state.playerSlots[slot] = nil
    state.selectedPlayerSlot = nil
    state.status = "DEPOSIT"
    refreshPanel(ctx)
    processTransferQueue(ctx)
end

local function depositHand(ctx)
    queueOperation("deposit", nil, 64, { hand = true, count = 64 },
        function(ok, data, err)
        ctx.notify(ok and ("Deposited " .. tostring(data and data.moved or 0))
            or ("Deposit: " .. tostring(err)),
            ok and ctx.config.theme.green or ctx.config.theme.red)
    end)
    refreshPanel(ctx)
    processTransferQueue(ctx)
end

local function movePointer(ctx, dx, dy)
    local widgets = state.widgets
    if not widgets then return end
    state.pointerX = util.clamp((state.pointerX or widgets.gridX) + dx,
        widgets.panelX + 3, widgets.panelX + widgets.panelW - 3)
    state.pointerY = util.clamp((state.pointerY or widgets.gridY) + dy,
        widgets.panelY + 3, widgets.panelY + widgets.panelH - 3)

    state.hoveredQueueSlot = nil
    if widgets.queueRows
            and state.pointerX >= widgets.queueX
            and state.pointerX < widgets.queueX + widgets.queueWidth
            and state.pointerY >= widgets.queueY
            and state.pointerY < widgets.queueY + widgets.queueSlotSize then
        state.hoveredQueueSlot = math.floor(
            (state.pointerX - widgets.queueX) / widgets.queueSlotSize) + 1
    end

    if state.view == "inventory" then
        local relativeX = state.pointerX - widgets.inventoryGridX
        local relativeY = state.pointerY - widgets.inventoryGridY
        if relativeX >= 0 and relativeX < widgets.inventoryGridW
                and relativeY >= 0 and relativeY < widgets.inventoryGridH then
            local column = math.floor(relativeX / INVENTORY_SLOT_SIZE)
            local row = math.floor(relativeY / INVENTORY_SLOT_SIZE)
            local slot = playerSlotForCell(
                row * INVENTORY_COLUMNS + column + 1)
            if state.playerSlots[slot] then state.selectedPlayerSlot = slot end
        end
    else
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
    end
    state.pointerDirty = true
    local now = util.epoch()
    if now - state.lastPointerFlush >= CURSOR_FLUSH_INTERVAL_MS then
        state.lastPointerFlush = now
        objectCall(widgets.cursorRing, "setPos", state.pointerX, state.pointerY, 97)
        if ctx.system.flushOverlay then pcall(ctx.system.flushOverlay) end
    end
end

local function mouseDelta(first, second, third)
    local dx, dy
    if type(first) == "number" then dx, dy = dy, first end
    if type(second) == "number" then dx, dy = dy, second end
    if type(third) == "number" then dx, dy = dy, third end
    return dx or 0, dy or 0
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
            local dx, dy = mouseDelta(sender, message, protocol)
            movePointer(ctx, dx, dy)
            return true
        elseif event == "player_mouse_scroll" then
            if state.view ~= "storage" then return true end
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
                    and pointerInside(widgets.storageTabX, widgets.storageTabY,
                        widgets.storageTabW, widgets.storageTabH) then
                setView(ctx, "storage")
                return true
            end
            if widgets and button == 1
                    and pointerInside(widgets.inventoryTabX, widgets.inventoryTabY,
                        widgets.inventoryTabW, widgets.inventoryTabH) then
                setView(ctx, "inventory")
                return true
            end
            if widgets and state.view == "inventory"
                    and pointerInside(widgets.inventoryGridX, widgets.inventoryGridY,
                        widgets.inventoryGridW, widgets.inventoryGridH) then
                local column = math.floor(
                    (state.pointerX - widgets.inventoryGridX) / INVENTORY_SLOT_SIZE)
                local row = math.floor(
                    (state.pointerY - widgets.inventoryGridY) / INVENTORY_SLOT_SIZE)
                local slot = playerSlotForCell(
                    row * INVENTORY_COLUMNS + column + 1)
                state.selectedPlayerSlot = slot
                depositPlayerSlot(ctx, slot)
                return true
            end
            if state.view ~= "storage" then return true end
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
            if keys.i and code == keys.i then
                setView(ctx, state.view == "storage" and "inventory" or "storage")
                return true
            end
            if state.view ~= "storage" then return true end
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
    if state.panelOpen and state.pointerDirty and state.widgets then
        updatePanel(ctx)
    end
    if state.panelOpen and state.drawAt and now >= state.drawAt then
        state.drawAt = nil
        drawPanel(ctx)
    end
    if state.panelOpen and state.searchAt and now >= state.searchAt then
        state.searchAt = nil
        refresh(ctx, state.query)
    end
    if pruneTransferQueue(now) and state.panelOpen then refreshPanel(ctx) end
    for id, pending in pairs(state.pending) do
        local timeout = pending.operation == "craft" and 50000 or 8000
        if now - pending.started > timeout then
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
    state.pointerDirty = false
    state.lastPointerFlush = 0
    state.hoveredQueueSlot = nil
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
    state.pointerDirty = false
    state.lastPointerFlush = 0
    state.hoveredQueueSlot = nil
end

api.registerApp(app)
return app
