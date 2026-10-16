local api = require("m2os.api")
local util = require("m2os.lib.util")

local Kernel = {}
Kernel.__index = Kernel

local function removeOverlayObject(overlay, object)
    if not object then return end
    pcall(function() overlay.removeObject(object.getId()) end)
end

function Kernel.new(config)
    local overlay = util.module("overlay")
    if not overlay then error("Smart Glasses overlay module not found", 0) end

    local self = setmetatable({
        config = config,
        overlay = overlay,
        apps = {},
        appOrder = {},
        services = {},
        actions = {},
        running = true,
        inputMode = nil,
        state = util.readTable(config.stateFile, { enabled = {} }),
        width = 0,
        height = 0,
        scale = 1,
        notice = nil
    }, Kernel)
    self.state.enabled = self.state.enabled or {}
    self:_measure()
    return self
end

function Kernel:_measure()
    local width, height, scale = self.overlay.getGuiSize()
    scale = scale or 1
    self.width, self.height, self.scale = width / scale, height / scale, scale
    return self.width, self.height
end

function Kernel:_saveState()
    local ok, err = util.writeTable(self.config.stateFile, self.state)
    if not ok then print("M2OS state: " .. tostring(err)) end
end

function Kernel:_owner(id)
    return self.apps[id]
end

function Kernel:_makeUi(owner)
    local overlay = self.overlay
    local ui = {}

    function ui.raw(kind, properties)
        local creator = overlay["create" .. kind]
        assert(type(creator) == "function", "unknown overlay object " .. tostring(kind))
        local object = creator(properties)
        owner.objects[object] = true
        return object
    end

    function ui.rectangle(x, y, width, height, color, opacity, z)
        return ui.raw("Rectangle", {
            gui = true, x = x + width / 2, y = y + height / 2, z = z or 0,
            sizeX = width, sizeY = height, color = color, opacity = opacity or 1
        })
    end

    function ui.textureRect(x, y, width, height, color, opacity, z)
        local texture = ui.raw("Texture", {
            gui = true, x = x, y = y, z = z or 0, sizeX = width, sizeY = height,
            color = color, opacity = opacity or 1, culling = false,
            depthTest = false, depthMask = false
        })
        texture.setImageSize(1, 1)
        texture.setPixel(1, 1, -1)
        return texture
    end

    function ui.line(x1, y1, x2, y2, color, opacity, width, z)
        return ui.raw("Line", {
            gui = true, x = x1, y = y1, z = z or 20,
            endX = x2, endY = y2, color = color,
            opacity = opacity or 1, width = width or 1
        })
    end

    function ui.text(x, y, content, color, size, z, shadow)
        return ui.raw("Text", {
            gui = true, x = x, y = y, z = z or 5,
            content = tostring(content or ""), color = color,
            fontSize = size or 1, shadow = shadow ~= false
        })
    end

    function ui.remove(object)
        owner.objects[object] = nil
        removeOverlayObject(overlay, object)
    end

    function ui.clear()
        for object in pairs(owner.objects) do removeOverlayObject(overlay, object) end
        owner.objects = {}
    end

    return ui
end


function Kernel:_makeContext(owner)
    local kernel = self
    local ctx = {
        app = owner.definition,
        config = self.config,
        ui = self:_makeUi(owner)
    }

    ctx.system = {
        getSize = function() return kernel.width, kernel.height, kernel.scale end,
        getEyePosition = function() return kernel.overlay.getEyePosition() end,
        getModule = util.module,
        getInputMode = function() return kernel.inputMode end,
        setInputMode = function(mode) kernel.inputMode = mode end,
        isEnabled = function(id) return kernel.apps[id] and kernel.apps[id].enabled or false end,
        enable = function(id, enabled) return kernel:setEnabled(id, enabled) end,
        stop = function() kernel.running = false end,
        emit = function(name, ...) os.queueEvent(name, ...) end,
        -- Used by latency-sensitive input cursors. Callers must throttle this;
        -- normal UI updates remain batched by the kernel tick.
        flushOverlay = function() kernel.overlay.update() end,
        now = util.epoch
    }

    ctx.services = {
        provide = function(name, methods)
            assert(type(name) == "string" and type(methods) == "table", "invalid service")
            kernel.services[name] = { owner = owner.definition.id, methods = methods }
        end,
        get = function(name)
            local service = kernel.services[name]
            return service and service.methods or nil
        end
    }

    ctx.menu = {
        add = function(action)
            assert(type(action) == "table" and action.id and action.label and action.run,
                "menu action needs id, label and run")
            action.owner = owner.definition.id
            kernel.actions[action.id] = action
        end,
        getAll = function()
            local list = {}
            for _, action in pairs(kernel.actions) do list[#list + 1] = action end
            table.sort(list, function(a, b)
                return (a.order or 100) < (b.order or 100)
                    or ((a.order or 100) == (b.order or 100) and a.id < b.id)
            end)
            return list
        end
    }

    ctx.notify = function(message, color) kernel:notify(message, color) end
    return ctx
end

function Kernel:register(definition)
    if self.apps[definition.id] then error("duplicate app: " .. definition.id) end
    local owner = {
        definition = definition,
        objects = {},
        enabled = false,
        failures = 0
    }
    owner.context = self:_makeContext(owner)
    self.apps[definition.id] = owner
    self.appOrder[#self.appOrder + 1] = owner

    if definition.userToggle ~= false then
        self.actions["toggle." .. definition.id] = {
            id = "toggle." .. definition.id,
            label = definition.menuLabel or definition.name or definition.id,
            order = definition.menuOrder or 100,
            owner = "__kernel",
            checked = function() return owner.enabled end,
            run = function() self:setEnabled(definition.id, not owner.enabled) end
        }
    end
end

function Kernel:_dropOwned(owner)
    owner.context.ui.clear()
    for name, service in pairs(self.services) do
        if service.owner == owner.definition.id then self.services[name] = nil end
    end
    for id, action in pairs(self.actions) do
        if action.owner == owner.definition.id then self.actions[id] = nil end
    end
end

function Kernel:setEnabled(id, enabled)
    local owner = self.apps[id]
    if not owner then return false, "unknown app " .. tostring(id) end
    enabled = not not enabled
    if owner.enabled == enabled then return true end

    if enabled then
        owner.enabled = true
        local ok, err = pcall(function()
            if owner.definition.start then owner.definition.start(owner.context) end
        end)
        if not ok then
            owner.enabled = false
            self:_dropOwned(owner)
            self:notify(id .. ": " .. tostring(err), self.config.theme.red)
            return false, err
        end
    else
        if owner.definition.stop then pcall(owner.definition.stop, owner.context) end
        owner.enabled = false
        self:_dropOwned(owner)
    end

    if owner.definition.persistent ~= false then
        self.state.enabled[id] = enabled
        self:_saveState()
    end
    return true
end

function Kernel:notify(message, color)
    print("[M2OS] " .. tostring(message))
    self.notice = { text = tostring(message), color = color, expires = util.epoch() + 3500 }
    os.queueEvent("m2os_notice", self.notice.text, self.notice.color)
end

function Kernel:_invoke(owner, method, ...)
    local callback = owner.definition[method]
    if not callback or not owner.enabled then return end
    local ok, result = pcall(callback, owner.context, ...)
    if ok then
        owner.failures = 0
        return result
    end
    local err = result
    owner.failures = owner.failures + 1
    print(("[%s/%s] %s"):format(owner.definition.id, method, tostring(err)))
    if owner.failures >= 3 then
        self:notify(owner.definition.id .. " disabled after errors", self.config.theme.red)
        self:setEnabled(owner.definition.id, false)
    end
end

function Kernel:_loadApps()
    for _, moduleName in ipairs(self.config.modules) do require(moduleName) end
    for _, definition in pairs(api.getApps()) do self:register(definition) end
    table.sort(self.appOrder, function(a, b)
        return (a.definition.priority or 100) < (b.definition.priority or 100)
    end)
end

function Kernel:_startApps()
    for _, owner in ipairs(self.appOrder) do
        local saved = self.state.enabled[owner.definition.id]
        local enabled = saved
        if enabled == nil then enabled = owner.definition.defaultEnabled ~= false end
        if owner.definition.required then enabled = true end
        self:setEnabled(owner.definition.id, enabled)
    end
end

function Kernel:_shutdown()
    for index = #self.appOrder, 1, -1 do
        local owner = self.appOrder[index]
        if owner.enabled and owner.definition.stop then pcall(owner.definition.stop, owner.context) end
        self:_dropOwned(owner)
        owner.enabled = false
    end
    pcall(self.overlay.update)
end

function Kernel:loop()
    self.overlay.setAutoUpdate(false)
    self:_loadApps()
    self:_startApps()
    self:notify(self.config.name .. " " .. self.config.version .. " online", self.config.theme.green)

    local lastTick = util.epoch()
    local timer = os.startTimer(0.05)
    while self.running do
        local event = { os.pullEventRaw() }
        if event[1] == "terminate" then
            self.running = false
        elseif event[1] == "timer" and event[2] == timer then
            local now = util.epoch()
            local oldWidth, oldHeight = self.width, self.height
            self:_measure()
            if oldWidth ~= self.width or oldHeight ~= self.height then
                for _, owner in ipairs(self.appOrder) do
                    self:_invoke(owner, "resize", self.width, self.height)
                end
            end
            for _, owner in ipairs(self.appOrder) do
                self:_invoke(owner, "update", now, (now - lastTick) / 1000)
            end
            lastTick = now
            self.overlay.update()
            timer = os.startTimer(0.05)
        else
            for _, owner in ipairs(self.appOrder) do
                if self:_invoke(owner, "onEvent", table.unpack(event)) then break end
            end
        end
    end
    self:_shutdown()
end

function Kernel.run(config)
    local kernel = Kernel.new(config)
    local traceback = debug and debug.traceback or function(value) return tostring(value) end
    local ok, err = xpcall(function() kernel:loop() end, traceback)
    if not ok then
        kernel:_shutdown()
        error(err, 0)
    end
end

return Kernel
