local api = require("m2os.api")
local util = require("m2os.lib.util")

local app = {
    id = "context",
    name = "Context Inspector",
    menuLabel = "CONTEXT INFO",
    menuOrder = 40,
    priority = 30,
    defaultEnabled = true
}

local state = {
    target = nil,
    details = nil,
    expires = 0,
    providers = {},
    keyboard = nil
}

local function numberField(tableValue, names)
    if type(tableValue) ~= "table" then return nil end
    for _, name in ipairs(names) do
        local value = tonumber(tableValue[name])
        if value then return value end
    end
end

local function blockFromArguments(...)
    local arguments = { ... }
    for _, value in ipairs(arguments) do
        if type(value) == "table" then
            if type(value.block_state) == "table" then return value.block_state end
            if type(value.blockState) == "table" then return value.blockState end
            if value.name and (value.x or value.pos) then return value end
            for _, child in pairs(value) do
                if type(child) == "table" and child.name and (child.x or child.pos) then
                    return child
                end
            end
        end
    end
end

local function coordinates(target)
    if not target then return nil end
    if type(target.pos) == "table" then
        return target.pos.x or target.pos[1], target.pos.y or target.pos[2], target.pos.z or target.pos[3]
    end
    return target.x, target.y, target.z
end

local function draw(ctx)
    ctx.ui.clear()
    if not state.target then return end
    local width, height = ctx.system.getSize()
    local theme = ctx.config.theme
    local panelW, panelH = 184, state.details and 82 or 62
    local x, y = width / 2 + 13, height / 2 + 12
    if x + panelW > width - 8 then x = width / 2 - panelW - 13 end

    ctx.ui.textureRect(x, y, panelW, panelH, theme.background, 0.82, 55)
    ctx.ui.rectangle(x, y, 3, panelH, theme.blue, 1, 57)
    ctx.ui.text(x + 9, y + 7, "TARGET", theme.blue, 0.78, 60)
    ctx.ui.text(x + 9, y + 19,
        util.short(state.target.displayName or state.target.name or "unknown block", 30),
        theme.white, 0.90, 60)

    local px, py, pz = coordinates(state.target)
    if px and py and pz then
        ctx.ui.text(x + 9, y + 33, ("%d / %d / %d"):format(px, py, pz), theme.gray, 0.72, 60)
    end

    if state.details then
        if state.details.capacity then
            local percent = math.floor((state.details.fullness or 0) * 100 + 0.5)
            ctx.ui.text(x + 9, y + 48,
                ("STORAGE %d%%  %d/%d slots"):format(percent,
                    state.details.usedSlots or 0, state.details.capacity),
                percent > 90 and theme.red or theme.green, 0.78, 60)
        elseif state.details.progress then
            ctx.ui.text(x + 9, y + 48,
                ("PROCESS %d%%"):format(math.floor(state.details.progress * 100 + 0.5)),
                theme.purple, 0.82, 60)
        elseif state.details.message then
            ctx.ui.text(x + 9, y + 48, util.short(state.details.message, 30), theme.gray, 0.75, 60)
        end
    end
end

local function requestDetails(ctx, target)
    local storage = ctx.services.get("storage")
    local x, y, z = coordinates(target)
    if not storage or not x or not y or not z then return end
    storage.inspect({
        dimension = target.dimension or ctx.config.context.dimension,
        x = math.floor(x), y = math.floor(y), z = math.floor(z)
    }, function(ok, data)
        if ok and state.target == target then
            state.details = data
            draw(ctx)
        end
    end)
end

local function show(ctx, target, details)
    state.target = target
    state.details = details
    state.expires = util.epoch() + ctx.config.context.visibleSeconds * 1000
    for _, provider in pairs(state.providers) do
        local ok, value = pcall(provider, target)
        if ok and value then state.details = value break end
    end
    draw(ctx)
    if not state.details then requestDetails(ctx, target) end
end

function app.start(ctx)
    state.target, state.details = nil, nil
    state.keyboard = ctx.system.getModule("keyboard")
    if state.keyboard then
        -- AP only emits player_interaction for buttons explicitly claimed here.
        pcall(state.keyboard.setHandlingInteraction, 1, true)
    end
    ctx.services.provide("context", {
        show = function(target, details) show(ctx, target, details) end,
        hide = function() state.target = nil draw(ctx) end,
        addProvider = function(id, provider) state.providers[id] = provider end,
        removeProvider = function(id) state.providers[id] = nil end
    })
end

function app.onEvent(ctx, event, ...)
    if event ~= "player_interaction" then return end
    local target = blockFromArguments(...)
    if target then show(ctx, target) end
end

function app.update(ctx, now)
    if state.target and now >= state.expires then
        state.target, state.details = nil, nil
        draw(ctx)
    end
end

function app.resize(ctx)
    if state.target then draw(ctx) end
end

function app.stop(ctx)
    if state.keyboard then pcall(state.keyboard.setHandlingInteraction, 1, false) end
    state.keyboard = nil
    state.target, state.details = nil, nil
    ctx.ui.clear()
end

api.registerApp(app)
return app
