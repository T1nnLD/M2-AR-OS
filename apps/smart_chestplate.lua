local api = require("m2os.api")
local util = require("m2os.lib.util")
local Chest = require("m2os.lib.smart_chestplate")
local Combat = require("m2os.lib.chestplate_combat")

local app = {
    id = "smart_chestplate", name = "Умный нагрудник · эксперимент",
    priority = 15, userToggle = false, persistent = false, defaultEnabled = true
}

local state = {}
local draw, render, close, refresh, perform, toggleCombat
local LABELS = { attack = "Удар", dig = "Копать", use = "Использовать",
    suck = "Подобрать", drop = "Выбросить" }

local function numericArguments(...)
    local result = {}
    for _, value in ipairs({...}) do
        if type(value) == "number" then result[#result+1] = value end
    end
    return result
end

local function buttonAtPointer()
    local widgets = state.widgets
    if not widgets then return end
    for _, hit in ipairs(widgets.buttons) do
        if state.pointerX >= hit.x and state.pointerX < hit.x+hit.w
                and state.pointerY >= hit.y and state.pointerY < hit.y+hit.h then
            return hit
        end
    end
end

local function highlight(ctx, hit)
    local widgets = state.widgets
    if not widgets then return end
    state.focus = hit and hit.id or nil
    if widgets.highlighted == hit then return end
    if widgets.highlighted then widgets.highlighted.background.setColor(widgets.highlighted.color) end
    if hit then hit.background.setColor(0x445470) end
    widgets.highlighted = hit
    widgets.hint.setContent(hit and ("Выбрано: " .. hit.label .. " · ЛКМ / Enter")
        or "Tab/Enter: кнопки  1–5: рука  R: инвентарь  Esc: закрыть")
end

local function report(ctx, message, bad)
    state.message = tostring(message)
    state.bad = bad == true
    state.dirty = true
    if bad then print("[Smart Chestplate] " .. state.message) end
end

local function remember()
    state.saveDirty = true
    state.saveAt = state.saveAt or (util.epoch()+500)
end

local function saveState(ctx, force)
    if not state.path or not state.saveDirty then return end
    if not force and util.epoch() < (state.saveAt or 0) then return end
    local payload = {version=1,hand=state.hand,sourceSlot=state.sourceSlot,linked=state.linked,
        lastOnline=state.online,positions=state.positions,receipts=state.receipts,
        autoAttack=state.combat.enabled}
    local ok, written, err = pcall(util.writeTable,state.path,payload)
    if ok and written then state.saveDirty=false state.saveAt=nil
    else
        state.saveAt=util.epoch()+5000
        report(ctx,"Не удалось сохранить нагрудник: " .. tostring(ok and err or written),true)
    end
end

local function selectHand(ctx, hand)
    state.hand = hand
    local ok, position = state.chest:position(hand)
    state.position = ok and position or nil
    if ok then state.positions[hand]=position end
    if not ok then report(ctx, position, true) end
    state.dirty = true
    remember()
end

refresh = function(ctx, inventory)
    local ok, result = state.chest:probe()
    state.online = ok
    state.checkAt = util.epoch()+5000
    if not ok then
        state.position = nil
        state.inventory = nil
        report(ctx, result, true)
        if state.combat.enabled then state.combat:stop(result) end
        remember()
        return
    end
    state.linked = true
    local restoreError
    if state.restorePending then
        state.restorePending = false
        for hand = 1, 5 do
            if state.positions[hand] then
                local moved, reason = state.chest:move(hand,state.positions[hand])
                if not moved then restoreError=reason break end
            end
        end
    end
    report(ctx, "Нагрудник подключён. Состояние сохранено.")
    selectHand(ctx, state.hand)
    if restoreError then report(ctx,"Не удалось восстановить положение рук: " .. tostring(restoreError),true) end
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
    if state.combat.enabled then report(ctx,"Выключи автоатаку перед ручным перемещением",true) return end
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
    state.combat.blocked={}
    remember()
end

perform = function(ctx, action)
    if state.combat.enabled then report(ctx,"Выключи автоатаку перед ручными действиями",true) return end
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
    remember()
end

close = function(ctx)
    saveState(ctx,true)
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
    local keyboard = ctx.system.getModule("keyboard")
    if not keyboard then
        ctx.notify("Для панели нагрудника нужен модуль Keyboard", ctx.config.theme.amber)
        return
    end
    if type(keyboard.setCaptureMouse) == "function" then pcall(keyboard.setCaptureMouse, true) end
    state.open = true
    ctx.system.setInputMode(app.id)
    state.pointerX, state.pointerY = nil, nil
    state.widgets = nil
    state.focus = "refresh"
    state.drawAt = nil
    state.position = state.positions[state.hand]
    state.inventory = nil
    if state.linked then
        state.checkAt = util.epoch()+50
        report(ctx,"Подключение запомнено. Проверяю наличие нагрудника…")
    else report(ctx, "Панель открыта. Нажми «Проверить» для подключения нагрудника.") end
    -- The radial menu already settled the current KeyboardScreen geometry.
    -- Draw before any native chest call: smartHandPos creates a hand entity
    -- in AP, so it is not an appropriate prerequisite for displaying a panel.
    render(ctx)
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
        local color = selected and theme.purple or 0x293044
        local background = rect(x, y, w, h, color)
        text(x + 4, y + 5, label)
        widgets.buttons[#widgets.buttons + 1] = {
            id = id, x = left+x*scale, y = top+y*scale, w = w*scale, h = h*scale,
            label = label, run = action, background = background, color = color
        }
    end
    ctx.ui.textureRect(left, top, 420 * scale, 354 * scale, theme.background, 1, 70)
    rect(0, 0, 420, 2, theme.purple, 72)
    text(12, 10, "НАГРУДНИК · EXPERIMENTAL", theme.white, 1)
    button("auto", 205, 7, 94, 20, state.combat.enabled and "Авто: ВКЛ" or "Авто: ВЫКЛ",
        function() toggleCombat(ctx) end,state.combat.enabled)
    text(12, 27, state.online and "Подключён / 5 рук" or "Нажми «Проверить» для подключения",
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
        if state.combat.enabled then report(ctx,"Сначала выключи автоатаку",true) return end
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
            remember()
        end, state.sourceSlot == slot)
    end
    local item = state.inventory and (state.inventory[state.sourceSlot] or state.inventory[tostring(state.sourceSlot)])
    local label = type(item) == "table" and (util.itemLabel(item) .. " x" .. tostring(item.count or "?"))
        or (state.inventory and "Слот пуст" or "1–9: хотбар; 10–36: инвентарь. Чтение — по кнопке.")
    text(12, 295, util.short(label, 67), theme.gray, 0.72)
    text(12, 307, util.short(state.message or "", 67), state.bad and theme.red or theme.white, 0.72)
    text(12, 319, util.short(state.combat.enabled and state.combat.message
        or ("Последняя команда руки: " .. (state.receipts[state.hand] or "нет")),67), theme.gray, 0.72)
    widgets.hint = text(12, 337, "Tab/Enter: кнопки  1–5: рука  R: инвентарь  Esc: закрыть", theme.gray, 0.68)
    state.pointerX = util.clamp(state.pointerX or width / 2, left, left + 420 * scale)
    state.pointerY = util.clamp(state.pointerY or height / 2, top, top + 354 * scale)
    widgets.cursor = util.createTopCursor(ctx.ui, state.pointerX, state.pointerY, 90, theme)
    for _, hit in ipairs(widgets.buttons) do
        if hit.id == state.focus then highlight(ctx, hit) break end
    end
    state.dirty = false
end

local function activate(ctx, hit)
    if not hit then return end
    state.focus = hit.id
    report(ctx, "Выполняется: " .. hit.label)
    -- Publish click feedback before a synchronous AP operation can yield.
    if not render(ctx) then return end
    print("[Smart Chestplate] button: " .. hit.id)
    local ok, err = pcall(hit.run)
    if not ok then report(ctx, err, true) end
    if state.open then render(ctx) end
end

render = function(ctx)
    local ok, err = pcall(function()
        draw(ctx)
        ctx.system.flushOverlay()
    end)
    if not ok then
        -- A failed draw must not leave an invisible modal claiming input.
        close(ctx)
        ctx.notify("Нагрудник: ошибка интерфейса: " .. tostring(err), ctx.config.theme.red)
        return false
    end
    return true
end

toggleCombat = function(ctx)
    if state.combat.enabled then
        state.combat:setEnabled(false)
        report(ctx,"Автоатака выключена")
    else
        refresh(ctx,false)
        if not state.online then return end
        state.combat:setEnabled(true)
        report(ctx,"Автоатака включена: все мобы, игроки исключены")
    end
    remember()
    saveState(ctx,true)
end

function app.start(ctx)
    local options=ctx.config.chestplate or {}
    local path=options.stateFile
    if path==nil then path="/m2os-chestplate.cfg" end
    local ok,saved=true,{}
    if path then ok,saved=pcall(util.readTable,path,{}) end
    saved=ok and type(saved)=="table" and saved.version==1 and saved or {}
    local function index(value,max)
        return type(value)=="number" and value==value and value>=1 and value<=max and math.floor(value) or 1
    end
    local positions,receipts={},{}
    for hand=1,5 do
        local position=type(saved.positions)=="table" and saved.positions[hand]
        if type(position)=="table" then
            local copy,valid={},true
            for _,key in ipairs({"x","y","z","pitch","yaw"}) do
                local value=tonumber(position[key])
                if not value or value~=value or math.abs(value)==math.huge then valid=false break end
                copy[key]=value
            end
            if valid and copy.x*copy.x+copy.y*copy.y+copy.z*copy.z<=100 then positions[hand]=copy end
        end
        local receipt=type(saved.receipts)=="table" and saved.receipts[hand]
        if type(receipt)=="string" then receipts[hand]=util.short(receipt,100) end
    end
    state = { open = false, hand = index(saved.hand,5), sourceSlot = index(saved.sourceSlot,36),
        receipts = receipts, positions = positions, restorePending = true,
        linked=saved.linked==true,path=path,
        chest = Chest.new(smartglasses), message = "", online = false }
    state.combat=Combat.new(ctx,state.chest)
    state.combat:setEnabled(saved.autoAttack==true)
    if state.linked or state.combat.enabled then state.checkAt=util.epoch()+250 end
    ctx.menu.add({ id = "smart_chestplate.panel", label = "НАГРУДНИК [EXP]", order = 35,
        keepInput = true, checked = function() return state.open end,
        run = function() show(ctx) end })
    ctx.services.provide("smart_chestplate", {
        show = function() if not state.open then show(ctx) end end,
        hide = function() close(ctx) end,
        status = function() return { open = state.open, online = state.online, hand = state.hand,
            sourceSlot=state.sourceSlot,linked=state.linked,autoAttack=state.combat.enabled } end,
        setAutoAttack = function(enabled)
            if state.combat.enabled ~= (enabled==true) then toggleCombat(ctx) end
        end
    })
end

function app.onEvent(ctx, event, ...)
    if not state.open then return end
    if event == "keyboard_close" then close(ctx) return true end
    if event == "player_mouse_move" then
        local numbers = numericArguments(...)
        local w = state.widgets
        if w then
            state.pointerX = util.clamp(state.pointerX + (numbers[#numbers-1] or 0), w.left, w.left+420*w.scale)
            state.pointerY = util.clamp(state.pointerY + (numbers[#numbers] or 0), w.top, w.top+354*w.scale)
            util.moveTopCursor(w.cursor, state.pointerX, state.pointerY, 90)
            highlight(ctx, buttonAtPointer())
            local now = util.epoch()
            if now >= (state.flushAt or 0) then
                state.flushAt = now + 25
                ctx.system.flushOverlay()
            end
        end
        return true
    elseif event == "player_mouse_click" then
        local numbers = numericArguments(...)
        local button = numbers[1]
        if (button == 1 or button == 0) and state.widgets then
            local hit = buttonAtPointer()
            if hit then activate(ctx, hit)
            else report(ctx, "Клик вне кнопки — наведи курсор до подсветки") render(ctx) end
        end
        return true
    elseif event == "key" then
        local code = numericArguments(...)[1]
        local held = false
        for _, value in ipairs({...}) do if type(value) == "boolean" then held = value end end
        if held then return true end
        if code == keys.escape then close(ctx)
        elseif code == keys.r then refresh(ctx, true)
        elseif keys.tab and code == keys.tab and state.widgets then
            local buttons = state.widgets.buttons
            local nextIndex = 1
            for index, hit in ipairs(buttons) do
                if hit.id == state.focus then nextIndex = index % #buttons + 1 break end
            end
            highlight(ctx, buttons[nextIndex])
        elseif (keys.enter and code == keys.enter) or (keys.numPadEnter and code == keys.numPadEnter) then
            if state.widgets then
                for _, hit in ipairs(state.widgets.buttons) do
                    if hit.id == state.focus then activate(ctx, hit) break end
                end
            end
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
    if state.checkAt and now>=state.checkAt then refresh(ctx,false) end
    local enabled,message=state.combat.enabled,state.combat.message
    state.combat:update(now,state.online)
    if state.combat.lastPosition and state.positions[state.combat.lastHand]~=state.combat.lastPosition then
        state.positions[state.combat.lastHand]=state.combat.lastPosition
        if state.hand==state.combat.lastHand then state.position=state.combat.lastPosition end
        remember()
    end
    if enabled~=state.combat.enabled then
        remember()
        report(ctx,state.combat.message,true)
    end
    if message~=state.combat.message then state.dirty=true end
    saveState(ctx,false)
    if not state.open then return end
    if state.drawAt and now < state.drawAt then return end
    state.drawAt = nil
    if state.dirty or not state.widgets then render(ctx) end
end

function app.resize(ctx)
    if not state.open then return end
    -- Keep the displayed button geometry active until its replacement is
    -- ready, rather than discarding all click targets during resize bursts.
    -- Repeated resize packets must not push the first draw into the future
    -- forever. Keep the initial deadline and draw using the latest geometry.
    state.drawAt = state.drawAt or (util.epoch() + 180)
    state.dirty = true
end

function app.stop(ctx)
    close(ctx)
    state.combat:setEnabled(false)
end

api.registerApp(app)
return app
