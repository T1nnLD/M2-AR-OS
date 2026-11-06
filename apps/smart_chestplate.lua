local api = require("m2os.api")
local util = require("m2os.lib.util")
local Chest = require("m2os.lib.smart_chestplate")

local app = {
    id = "smart_chestplate", name = "Умный нагрудник · эксперимент",
    priority = 15, userToggle = false, persistent = false, defaultEnabled = true
}

local state = {}
local draw, close, refresh, perform
local LABELS = { attack = "Удар", dig = "Копать", use = "Использовать",
    suck = "Подобрать", drop = "Выбросить" }

local function report(ctx, message, bad)
    state.message = tostring(message)
    state.bad = bad == true
    state.dirty = true
    if bad then print("[Smart Chestplate] " .. state.message) end
end

local function selectHand(ctx, hand)
    state.hand = hand
    local ok, position = state.chest:position(hand)
    state.position = ok and position or nil
    if not ok then report(ctx, position, true) end
    state.dirty = true
end

refresh = function(ctx, inventory)
    local ok, result = state.chest:probe()
    state.online = ok
    if not ok then
        state.position = nil
        state.inventory = nil
        report(ctx, result, true)
        return
    end
    report(ctx, "Нагрудник подключён. Команды выполняются вручную.")
    selectHand(ctx, state.hand)
    if inventory then
        local listed, value = state.chest:inventory()
        if listed then
            state.inventory = value
            report(ctx, "Инвентарь игрока прочитан. Выбери слот для загрузки.")
        else
            state.inventory = nil
            report(ctx, value, true)
        end
    end
end

local function move(ctx, field, delta)
    if not state.position then report(ctx, "Сначала нажми «Проверить»", true) return end
    local nextPosition = {}
    for key, value in pairs(state.position) do nextPosition[key] = value end
    nextPosition[field] = nextPosition[field] + delta
    local ok, reason = state.chest:move(state.hand, nextPosition)
    if not ok then report(ctx, reason, true) return end
    selectHand(ctx, state.hand)
    report(ctx, "Рука " .. state.hand .. ": положение изменено")
end

local function transfer(ctx, load)
    if not state.online then report(ctx, "Сначала подключи нагрудник и нажми «Проверить»", true) return end
    local ok, value = state.chest:transfer(state.hand, state.sourceSlot, load)
    -- The list API does not expose hand contents; never present source slots
    -- as actual chestplate slots. Invalidate the source snapshot after a move.
    state.inventory = nil
    if ok then
        state.receipts[state.hand] = (load and "Загружено: +" or "Возвращено: -") .. value
        report(ctx, (load and "В руку перенесено: " or "В инвентарь возвращено: ") .. value)
    else
        report(ctx, value, true)
    end
end

perform = function(ctx, action)
    if not state.online then report(ctx, "Сначала подключи нагрудник и нажми «Проверить»", true) return end
    local now = util.epoch()
    -- One native action per explicit click, never repeated by update().
    if now < (state.nextAction or 0) then report(ctx, "Подожди завершения предыдущей команды", true) return end
    state.nextAction = now + 250
    local ok, result, detail = state.chest:action(state.hand, action)
    if not ok then report(ctx, result, true) return end
    state.receipts[state.hand] = LABELS[action] .. ": " .. tostring(result)
    local suffix = detail ~= nil and (" / " .. tostring(detail)) or ""
    report(ctx, LABELS[action] .. ": " .. tostring(result) .. suffix)
    if action == "drop" or action == "suck" or action == "use" then state.inventory = nil end
end

close = function(ctx)
    state.open = false
    state.widgets, state.drawAt = nil, nil
    state.dirty = false
    if ctx.system.getInputMode() == app.id then ctx.system.setInputMode(nil) end
    ctx.ui.clear()
end

local function show(ctx)
    if state.open then close(ctx) return end
    local mode = ctx.system.getInputMode()
    if mode and mode ~= app.id then
        ctx.notify("Сначала закрой текущее окно", ctx.config.theme.amber)
        return
    end
    if not ctx.system.getModule("keyboard") then
        ctx.notify("Для панели нагрудника нужен модуль Keyboard", ctx.config.theme.amber)
        return
    end
    state.open = true
    ctx.system.setInputMode(app.id)
    state.pointerX, state.pointerY = nil, nil
    state.widgets = nil
    state.drawAt = util.epoch() + 180
    refresh(ctx, false)
end

draw = function(ctx)
    ctx.ui.clear()
    if not state.open then return end
    local width, height = ctx.system.getSize()
    local scale = math.min(1, (width - 12) / 420, (height - 12) / 354)
    local left, top = (width - 420 * scale) / 2, (height - 354 * scale) / 2
    local theme = ctx.config.theme
    local widgets = { buttons = {}, left = left, top = top, scale = scale }
    state.widgets = widgets
    local function text(x, y, value, color, size)
        return ctx.ui.text(left + x * scale, top + y * scale, value,
            color or theme.white, (size or 0.8) * scale, 76, false)
    end
    local function rect(x, y, w, h, color, z)
        return ctx.ui.rectangle(left + x * scale, top + y * scale, w * scale, h * scale,
            color, 1, z or 73)
    end
    local function button(id, x, y, w, h, label, action, selected)
        rect(x, y, w, h, selected and theme.purple or 0x293044)
        text(x + 4, y + 5, label)
        widgets.buttons[#widgets.buttons + 1] = {
            id = id, x = x, y = y, w = w, h = h, run = action
        }
    end
    rect(0, 0, 420, 354, theme.background, 70)
    rect(0, 0, 420, 2, theme.purple, 72)
    text(12, 10, "НАГРУДНИК · EXPERIMENTAL", theme.white, 1)
    text(12, 27, state.online and "Подключён / 5 рук" or "Не подключён / API недоступен",
        state.online and theme.green or theme.amber)
    button("refresh", 305, 7, 102, 20, "Проверить", function() refresh(ctx, false) end)

    for hand = 1, 5 do
        local index = hand
        button("hand" .. index, 12 + (index - 1) * 80, 45, 74, 20,
            "Рука " .. index, function() selectHand(ctx, index) end, state.hand == index)
    end
    local p = state.position or {}
    for row, field in ipairs({ "x", "y", "z", "pitch", "yaw" }) do
        local name = field
        local step = (field == "pitch" or field == "yaw") and 15 or 0.25
        local y = 72 + (row - 1) * 20
        text(15, y + 5, field .. ": " .. (p[field] and ("%.2f"):format(p[field]) or "?"))
        button(field .. "-", 134, y, 25, 18, "-", function() move(ctx, name, -step) end)
        button(field .. "+", 164, y, 25, 18, "+", function() move(ctx, name, step) end)
    end
    local actions = { "attack", "dig", "use", "suck", "drop" }
    for row, action in ipairs(actions) do
        local name = action
        button(name, 216, 72 + (row - 1) * 20, 191, 18, LABELS[name], function() perform(ctx, name) end)
    end
    button("home", 12, 176, 88, 19, "Убрать руку", function()
        local ok, reason = state.chest:move(state.hand, {x=0,y=0,z=0,pitch=0,yaw=0})
        if ok then selectHand(ctx, state.hand) report(ctx, "Рука возвращена в исходное положение")
        else report(ctx, reason, true) end
    end)
    button("load", 106, 176, 96, 19, "В руку (стак)", function() transfer(ctx, true) end)
    button("unload", 208, 176, 96, 19, "В инвентарь", function() transfer(ctx, false) end)
    button("inventory", 310, 176, 97, 19, "Читать инв.", function() refresh(ctx, true) end)
    text(12, 202, "ИСТОЧНИК: инвентарь игрока · слот " .. state.sourceSlot, theme.gray)
    for slot = 1, 36 do
        local index = slot
        local x, y = 12 + ((slot - 1) % 9) * 44, 216 + math.floor((slot - 1) / 9) * 19
        local item = state.inventory and (state.inventory[slot] or state.inventory[tostring(slot)])
        button("slot" .. slot, x, y, 40, 17, tostring(slot) .. (item and " *" or ""), function()
            state.sourceSlot = index
            state.dirty = true
        end, state.sourceSlot == slot)
    end
    local item = state.inventory and (state.inventory[state.sourceSlot] or state.inventory[tostring(state.sourceSlot)])
    local label = type(item) == "table" and (util.itemLabel(item) .. " x" .. tostring(item.count or "?"))
        or (state.inventory and "Слот пуст" or "1–9: хотбар; 10–36: инвентарь. Чтение — по кнопке.")
    text(12, 295, util.short(label, 67), theme.gray, 0.72)
    text(12, 307, util.short(state.message or "", 67), state.bad and theme.red or theme.white, 0.72)
    text(12, 319, util.short("Последняя команда руки: " .. (state.receipts[state.hand] or "нет"), 67), theme.gray, 0.72)
    text(12, 337, "1–5: рука  R: читать инв.  Esc: закрыть  |  команды разовые", theme.gray, 0.68)
    state.pointerX = util.clamp(state.pointerX or width / 2, left, left + 420 * scale)
    state.pointerY = util.clamp(state.pointerY or height / 2, top, top + 354 * scale)
    widgets.cursor = util.createTopCursor(ctx.ui, state.pointerX, state.pointerY, 90, theme)
    state.dirty = false
end

function app.start(ctx)
    state = { open = false, hand = 1, sourceSlot = 1, receipts = {},
        chest = Chest.new(smartglasses), message = "", online = false }
    ctx.menu.add({ id = "smart_chestplate.panel", label = "НАГРУДНИК [EXP]", order = 35,
        keepInput = true, checked = function() return state.open end,
        run = function() show(ctx) end })
    ctx.services.provide("smart_chestplate", {
        show = function() if not state.open then show(ctx) end end,
        hide = function() close(ctx) end,
        status = function() return { open = state.open, online = state.online, hand = state.hand } end
    })
end

function app.onEvent(ctx, event, ...)
    if not state.open then return end
    if event == "keyboard_close" then close(ctx) return true end
    if event == "player_mouse_move" then
        local numbers = {}
        for _, value in ipairs({...}) do if type(value) == "number" then numbers[#numbers+1] = value end end
        local w = state.widgets
        if w then
            state.pointerX = util.clamp(state.pointerX + (numbers[#numbers-1] or 0), w.left, w.left+420*w.scale)
            state.pointerY = util.clamp(state.pointerY + (numbers[#numbers] or 0), w.top, w.top+354*w.scale)
            util.moveTopCursor(w.cursor, state.pointerX, state.pointerY, 90)
            local now = util.epoch()
            if now >= (state.flushAt or 0) then
                state.flushAt = now + 25
                ctx.system.flushOverlay()
            end
        end
        return true
    elseif event == "player_mouse_click" then
        local button = ...
        local w = state.widgets
        if button == 1 and w then
            local x, y = (state.pointerX-w.left)/w.scale, (state.pointerY-w.top)/w.scale
            for _, hit in ipairs(w.buttons) do
                if x >= hit.x and x < hit.x+hit.w and y >= hit.y and y < hit.y+hit.h then
                    hit.run()
                    break
                end
            end
        end
        return true
    elseif event == "key" then
        local code, held = ...
        if held then return true end
        if code == keys.escape then close(ctx)
        elseif code == keys.r then refresh(ctx, true)
        else
            for index, name in ipairs({"one", "two", "three", "four", "five"}) do
                if code == keys[name] then selectHand(ctx, index) break end
            end
        end
        return true
    elseif event == "char" or event == "key_up" or event == "player_mouse_scroll" then
        return true
    end
end

function app.update(ctx, now)
    if not state.open then return end
    if state.drawAt and now < state.drawAt then return end
    state.drawAt = nil
    if state.dirty or not state.widgets then draw(ctx) end
end

function app.resize(ctx)
    if not state.open then return end
    ctx.ui.clear()
    state.widgets = nil
    state.drawAt = util.epoch() + 180
    state.dirty = true
end

function app.stop(ctx)
    close(ctx)
end

api.registerApp(app)
return app
