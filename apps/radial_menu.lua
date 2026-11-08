local api = require("m2os.api")
local util = require("m2os.lib.util")

local app = {
    id = "radial_menu",
    name = "Radial Menu",
    priority = 1000,
    userToggle = false,
    required = true,
    persistent = false
}

local CURSOR_RADIUS = 52
local CURSOR_DEAD_ZONE = 8
local HOTKEY_LONG_PRESS = 600

local state = {
    visible = false,
    selected = 1,
    pointerX = 0,
    pointerY = 0,
    actions = {},
    armed = false,
    keyboard = nil,
    drawAt = nil,
    widgets = nil,
    waitingClose = false
}

local function atan2(y, x)
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if x == 0 and y > 0 then return math.pi / 2 end
    if x == 0 and y < 0 then return -math.pi / 2 end
    return 0
end

local function objectCall(object, method, ...)
    if not object then return false end
    local fn = object[method]
    if type(fn) ~= "function" then return false end
    return pcall(fn, ...)
end

local function isChecked(action)
    if not action or type(action.checked) ~= "function" then return false end
    local ok, checked = pcall(action.checked)
    return ok and checked == true
end

local function setPointerToSelected()
    if #state.actions == 0 then return end
    local angle = -math.pi / 2 + (state.selected - 1) * math.pi * 2 / #state.actions
    state.pointerX = math.cos(angle) * (CURSOR_RADIUS - 9)
    state.pointerY = math.sin(angle) * (CURSOR_RADIUS - 9)
end

local function updateVisuals(ctx)
    local widgets = state.widgets
    if not widgets then return end
    local theme = ctx.config.theme

    local cursorX = widgets.cx + state.pointerX
    local cursorY = widgets.cy + state.pointerY
    util.moveTopCursor(widgets.cursor, cursorX, cursorY, 97)

    for index, entry in ipairs(widgets.entries) do
        local selected = state.armed and index == state.selected
        local checked = isChecked(entry.action)
        local label = (checked and "+ " or "  ") .. entry.action.label
        objectCall(entry.background, "setOpacity", selected and 0.95 or 0.72)
        objectCall(entry.bar, "setColor",
            selected and theme.purple or (checked and theme.green or theme.blue))
        objectCall(entry.bar, "setSizes", selected and 3 or 1.5, entry.height)
        objectCall(entry.text, "setColor", selected and theme.white or theme.gray)
        objectCall(entry.text, "setContent", label)
    end
end

local function draw(ctx)
    ctx.ui.clear()
    state.widgets = nil
    if not state.visible then return end

    state.actions = ctx.menu.getAll()
    if #state.actions == 0 then return end
    state.selected = ((state.selected - 1) % #state.actions) + 1

    local width, height = ctx.system.getSize()
    local cx, cy = width / 2, height / 2
    local theme = ctx.config.theme
    local radiusX = math.min(120, width * 0.22)
    local radiusY = math.min(74, height * 0.22)
    local widgets = { cx = cx, cy = cy, entries = {} }
    state.widgets = widgets

    ctx.ui.raw("Circle", {
        gui = true, x = cx, y = cy, z = 80, radius = 28,
        color = theme.background, opacity = 0.88
    })
    ctx.ui.raw("Circle", {
        gui = true, x = cx, y = cy, z = 81, radius = 25,
        color = theme.blue, opacity = 0.12
    })
    ctx.ui.raw("Circle", {
        gui = true, x = cx, y = cy, z = 82, radius = CURSOR_DEAD_ZONE,
        filled = false, borderWidth = 1, color = theme.gray, opacity = 0.22
    })
    ctx.ui.text(cx - 17, cy - 5, "M2OS", theme.white, 0.9, 90)
    ctx.ui.text(cx - 22, cy + 7, "SELECT", theme.gray, 0.6, 90)

    for index, action in ipairs(state.actions) do
        local angle = -math.pi / 2 + (index - 1) * math.pi * 2 / #state.actions
        local x = cx + math.cos(angle) * radiusX
        local y = cy + math.sin(angle) * radiusY
        local checked = isChecked(action)
        local label = (checked and "+ " or "  ") .. action.label
        local boxW = math.max(72, #label * 5.3 + 12)
        local boxH = 19
        local left = x - boxW / 2
        local top = y - boxH / 2
        widgets.entries[index] = {
            action = action,
            height = boxH,
            background = ctx.ui.textureRect(left, top, boxW, boxH,
                theme.background, 0.72, 82),
            bar = ctx.ui.rectangle(left, top, 1.5, boxH,
                checked and theme.green or theme.blue, 1, 84),
            text = ctx.ui.text(left + 7, top + 5, label, theme.gray, 0.72, 88)
        }
    end

    widgets.cursor = util.createTopCursor(ctx.ui, cx, cy, 97, theme)
    updateVisuals(ctx)
end

local function showCloseHint(ctx)
    state.waitingClose = true
    ctx.ui.clear()
    state.widgets = nil
    local width, height = ctx.system.getSize()
    local theme = ctx.config.theme
    local cx, cy = width / 2, height / 2
    ctx.ui.textureRect(cx - 72, cy - 12, 144, 24, theme.background, 0.88, 90)
    ctx.ui.rectangle(cx - 72, cy - 12, 2, 24, theme.purple, 1, 92)
    ctx.ui.raw("Circle", {
        gui = true, x = cx - 57, y = cy, z = 94, radius = 5,
        filled = false, borderWidth = 1.5, color = theme.white, opacity = 1
    })
    ctx.ui.text(cx - 45, cy - 4, "ESC - RETURN TO GAME", theme.white, 0.72, 94)
end

local function show(ctx, armed)
    state.visible = true
    state.waitingClose = false
    state.armed = armed == true
    state.actions = ctx.menu.getAll()
    state.pointerX, state.pointerY = 0, 0
    if state.armed then setPointerToSelected() end

    -- KeyboardScreen changes GUI geometry a few ticks after keyboard_open.
    -- Wait for its resize events to settle, then create the menu only once.
    state.drawAt = util.epoch() + (state.keyboard and 180 or 0)
    ctx.ui.clear()
    state.widgets = nil
    if state.keyboard then pcall(state.keyboard.setCaptureMouse, true) end
    if state.drawAt <= util.epoch() then
        state.drawAt = nil
        draw(ctx)
    end
end

local function hide(ctx, execute, screenClosed)
    if not state.visible then return end
    local action = state.armed and state.actions[state.selected] or nil
    state.visible = false
    state.drawAt = nil
    ctx.ui.clear()
    state.widgets = nil

    local keepInput = false
    if execute and action then
        local ok, err = pcall(action.run)
        if not ok then ctx.notify("Menu: " .. tostring(err), ctx.config.theme.red) end
        keepInput = action.keepInput == true or ctx.system.getInputMode() ~= nil
    end

    -- AP 0.8.2a can release captured mouse movement, but its Lua API cannot
    -- close KeyboardScreen. Pretending it can leaves the player stuck in the
    -- screen. Interactive actions retain it; simple actions show the one real
    -- exit supported by the client: Escape.
    if state.keyboard and not keepInput and not screenClosed then
        showCloseHint(ctx)
    else
        state.waitingClose = false
    end
end

local function selectFromPointer(ctx)
    if #state.actions == 0 then return end
    local distance = math.sqrt(state.pointerX * state.pointerX + state.pointerY * state.pointerY)
    if distance < CURSOR_DEAD_ZONE then
        state.armed = false
        updateVisuals(ctx)
        return
    end

    local angle = atan2(state.pointerY, state.pointerX) + math.pi / 2
    if angle < 0 then angle = angle + math.pi * 2 end
    state.selected = math.floor(angle / (math.pi * 2) * #state.actions + 0.5)
        % #state.actions + 1
    state.armed = true
    updateVisuals(ctx)
end

local function movePointer(ctx, dx, dy)
    state.pointerX = state.pointerX + dx
    state.pointerY = state.pointerY + dy
    local distance = math.sqrt(state.pointerX * state.pointerX + state.pointerY * state.pointerY)
    if distance > CURSOR_RADIUS then
        local scale = CURSOR_RADIUS / distance
        state.pointerX = state.pointerX * scale
        state.pointerY = state.pointerY * scale
    end
    selectFromPointer(ctx)
end

local function numericArguments(...)
    local out = {}
    for _, value in ipairs({ ... }) do
        if type(value) == "number" then out[#out + 1] = value end
    end
    return out
end

function app.start(ctx)
    state.visible = false
    state.waitingClose = false
    state.selected = 1
    state.keyboard = ctx.system.getModule("keyboard")
    if state.keyboard then pcall(state.keyboard.setCaptureMouse, true) end
    ctx.menu.add({
        id = "system.refresh", label = "REFRESH UI", order = 90,
        run = function() ctx.system.emit("m2os_refresh") end
    })
end

function app.onEvent(ctx, event, ...)
    if event == "keyboard_open" then
        if not ctx.system.getInputMode() then show(ctx, false) end
    elseif event == "keyboard_close" then
        if state.waitingClose then
            state.waitingClose = false
            ctx.ui.clear()
        elseif state.visible then
            hide(ctx, true, true)
        end
        return true
    elseif event == "glasses_key_pressed" then
        -- Both modules use the same client hotkey. With Keyboard installed its
        -- release event is only a duplicate of keyboard_open.
        if state.keyboard then return true end
        local values = numericArguments(...)
        local duration = values[#values] or 0
        if not state.visible then
            show(ctx, true)
        elseif duration >= HOTKEY_LONG_PRESS then
            hide(ctx, true, true)
        elseif #state.actions > 0 then
            state.armed = true
            state.selected = state.selected % #state.actions + 1
            setPointerToSelected()
            updateVisuals(ctx)
        end
        return true
    elseif event == "player_mouse_move" and state.visible then
        local values = numericArguments(...)
        local dx, dy = values[#values - 1] or 0, values[#values] or 0
        movePointer(ctx, dx, dy)
        return true
    elseif event == "player_mouse_scroll" and state.visible then
        local values = numericArguments(...)
        local direction = values[1] or 1
        state.armed = true
        state.selected = ((state.selected - 1 + (direction > 0 and 1 or -1))
            % #state.actions) + 1
        setPointerToSelected()
        updateVisuals(ctx)
        return true
    elseif event == "player_mouse_click" and state.visible then
        hide(ctx, true, false)
        return true
    elseif event == "m2os_refresh" then
        local desktop = ctx.system.isEnabled("desktop")
        if desktop then
            ctx.system.enable("desktop", false)
            ctx.system.enable("desktop", true)
        end
    end
end

function app.update(ctx, now)
    if state.visible and state.drawAt and now >= state.drawAt then
        state.drawAt = nil
        draw(ctx)
    end
end

function app.resize(ctx)
    if state.visible then
        -- A new resize invalidates the tentative centre. Debounce the series of
        -- KeyboardScreen resize packets so no top-left-to-centre jump is shown.
        ctx.ui.clear()
        state.widgets = nil
        state.drawAt = util.epoch() + 180
    elseif state.waitingClose then
        showCloseHint(ctx)
    end
end

function app.stop(ctx)
    if state.keyboard then pcall(state.keyboard.setCaptureMouse, false) end
    state.keyboard = nil
    state.visible = false
    state.waitingClose = false
    state.drawAt = nil
    state.widgets = nil
    ctx.ui.clear()
end

api.registerApp(app)
return app
