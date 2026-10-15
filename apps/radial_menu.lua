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

local state = {
    visible = false,
    selected = 1,
    pointerX = 0,
    pointerY = -1,
    expires = 0,
    actions = {},
    armed = false,
    keyboard = nil
}

local function atan2(y, x)
    if x > 0 then return math.atan(y / x) end
    if x < 0 and y >= 0 then return math.atan(y / x) + math.pi end
    if x < 0 and y < 0 then return math.atan(y / x) - math.pi end
    if x == 0 and y > 0 then return math.pi / 2 end
    if x == 0 and y < 0 then return -math.pi / 2 end
    return 0
end

local function draw(ctx)
    ctx.ui.clear()
    if not state.visible then return end
    state.actions = ctx.menu.getAll()
    if #state.actions == 0 then return end
    state.selected = ((state.selected - 1) % #state.actions) + 1

    local width, height = ctx.system.getSize()
    local cx, cy = width / 2, height / 2
    local theme = ctx.config.theme
    local radiusX = math.min(120, width * 0.22)
    local radiusY = math.min(74, height * 0.22)

    ctx.ui.raw("Circle", {
        gui = true, x = cx, y = cy, z = 80, radius = 27,
        color = theme.background, opacity = 0.88
    })
    ctx.ui.raw("Circle", {
        gui = true, x = cx, y = cy, z = 81, radius = 25,
        color = theme.blue, opacity = 0.12
    })
    ctx.ui.text(cx - 17, cy - 5, "M2OS", theme.white, 0.9, 90)
    ctx.ui.text(cx - 22, cy + 7, "SELECT", theme.gray, 0.6, 90)

    for index, action in ipairs(state.actions) do
        local angle = -math.pi / 2 + (index - 1) * math.pi * 2 / #state.actions
        local x = cx + math.cos(angle) * radiusX
        local y = cy + math.sin(angle) * radiusY
        local selected = state.armed and index == state.selected
        local checked = action.checked and action.checked() or false
        local label = (checked and "+ " or "  ") .. action.label
        local boxW = math.max(72, #label * 5.3 + 12)
        local boxH = 19
        local left = x - boxW / 2
        local top = y - boxH / 2
        ctx.ui.textureRect(left, top, boxW, boxH, theme.background, selected and 0.95 or 0.72, 82)
        ctx.ui.rectangle(left, top, selected and 3 or 1.5, boxH,
            selected and theme.purple or (checked and theme.green or theme.blue), 1, 84)
        ctx.ui.text(left + 7, top + 5, label,
            selected and theme.white or theme.gray, 0.72, 88)
    end
end

local function show(ctx, armed)
    state.visible = true
    state.armed = armed == true
    state.pointerX, state.pointerY = 0, -1
    state.expires = util.epoch() + 3500
    draw(ctx)
end

local function hide(ctx, execute)
    if not state.visible then return end
    local action = state.armed and state.actions[state.selected] or nil
    state.visible = false
    ctx.ui.clear()
    if execute and action then
        local ok, err = pcall(action.run)
        if not ok then ctx.notify("Menu: " .. tostring(err), ctx.config.theme.red) end
    end
end

local function selectFromPointer(ctx)
    if #state.actions == 0 then return end
    local angle = atan2(state.pointerY, state.pointerX) + math.pi / 2
    if angle < 0 then angle = angle + math.pi * 2 end
    local index = math.floor(angle / (math.pi * 2) * #state.actions + 0.5) % #state.actions + 1
    state.armed = true
    if index ~= state.selected then
        state.selected = index
        draw(ctx)
    end
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
        hide(ctx, true)
    elseif event == "glasses_key_pressed" then
        -- Keyboard Module and Hotkey Module share the same Minecraft key (G by
        -- default). With both installed, pressing G first emits keyboard_open
        -- and releasing it emits glasses_key_pressed. Treat the latter as a
        -- duplicate, otherwise the radial menu immediately closes again.
        if state.keyboard then return true end
        if state.visible then hide(ctx, true) else show(ctx, true) end
    elseif event == "player_mouse_move" and state.visible then
        local values = numericArguments(...)
        local dx, dy = values[#values - 1] or 0, values[#values] or 0
        state.pointerX = util.clamp(state.pointerX + dx, -100, 100)
        state.pointerY = util.clamp(state.pointerY + dy, -100, 100)
        selectFromPointer(ctx)
        state.expires = util.epoch() + 3500
    elseif event == "player_mouse_scroll" and state.visible then
        local values = numericArguments(...)
        local direction = values[1] or 1
        state.armed = true
        state.selected = ((state.selected - 1 + (direction > 0 and 1 or -1)) % #state.actions) + 1
        state.expires = util.epoch() + 3500
        draw(ctx)
    elseif event == "player_mouse_click" and state.visible then
        hide(ctx, true)
    elseif event == "m2os_refresh" then
        local desktop = ctx.system.isEnabled("desktop")
        if desktop then
            ctx.system.enable("desktop", false)
            ctx.system.enable("desktop", true)
        end
    end
end

function app.update(ctx, now)
    if state.visible and now >= state.expires then hide(ctx, false) end
end

function app.resize(ctx)
    if state.visible then draw(ctx) end
end

function app.stop(ctx)
    if state.keyboard then pcall(state.keyboard.setCaptureMouse, false) end
    state.keyboard = nil
    state.visible = false
    ctx.ui.clear()
end

api.registerApp(app)
return app
