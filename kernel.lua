local api = require("m2os.api")
local util = require("m2os.lib.util")
local Scheduler = require("m2os.lib.scheduler")
local Window = require("m2os.lib.window")

local Kernel = {}
Kernel.__index = Kernel

local function mailbox() return {head=1,tail=0} end
local function enqueue(queue,event)
    local last=queue[queue.tail]
    -- Only adjacent motion events can be merged. A click is an ordering
    -- barrier, so it always sees the preceding mouse position.
    if last and last[1]=="player_mouse_move" and event[1]==last[1]
            and type(last[2])=="number" and type(last[3])=="number"
            and type(event[2])=="number" and type(event[3])=="number" then
        last[2]=last[2]+event[2] last[3]=last[3]+event[3]
    else queue.tail=queue.tail+1 queue[queue.tail]=event end
end
local function dequeue(queue)
    if queue.head>queue.tail then return end
    local event=queue[queue.head]
    queue[queue.head]=nil queue.head=queue.head+1
    if queue.head>queue.tail then queue.head=1 queue.tail=0 end
    return event
end
local INPUT={key=true,key_up=true,char=true,paste=true,keyboard_open=true,keyboard_close=true,
    glasses_key_pressed=true,player_interaction=true,player_mouse_move=true,player_mouse_click=true,
    player_mouse_up=true,player_mouse_scroll=true}

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
    ctx.ui.window=function(options)
        local window=Window.new(ctx,options)
        owner.windows[window]=true
        return window
    end

    ctx.system = {
        getSize = function() return kernel.width, kernel.height, kernel.scale end,
        getEyePosition = function() return kernel.overlay.getEyePosition() end,
        getModule = util.module,
        getInputMode = function() return kernel.inputMode end,
        setInputMode = function(mode)
            kernel.inputMode=mode kernel.inputOwner=mode and owner.definition.id or nil
        end,
        isEnabled = function(id) return kernel.apps[id] and kernel.apps[id].enabled or false end,
        enable = function(id, enabled) return kernel:setEnabled(id, enabled) end,
        stop = function()
            kernel.running=false
            if kernel.scheduler then kernel.scheduler:cancelAll() end
        end,
        emit = function(name, ...) os.queueEvent(name, ...) end,
        -- Used by latency-sensitive input cursors. Callers must throttle this;
        -- normal UI updates remain batched by the kernel tick.
        flushOverlay = function() kernel.overlay.update() end,
        restartSensor = function() kernel:_startSensor(owner) end,
        cancelSensor = function()
            if kernel.scheduler then kernel.scheduler:cancel(owner.definition.id..":__sensor") end
        end,
        now = util.epoch
    }

    ctx.tasks = {
        spawn = function(name,callback)
            assert(kernel.scheduler,"background tasks require a running kernel")
            assert(kernel.running and owner.enabled,"app is disabled or kernel is stopping")
            assert(type(name)=="string" and name:sub(1,2)~="__","invalid task name")
            assert(type(callback)=="function","task callback must be a function")
            kernel.scheduler:spawn(owner.definition.id..":"..name,function() callback(ctx) end,
                {owner=owner.definition.id,priority=100+ (owner.definition.priority or 100)})
            return name
        end,
        cancel = function(name)
            assert(type(name)=="string" and name:sub(1,2)~="__","invalid task name")
            if kernel.scheduler then return kernel.scheduler:cancel(owner.definition.id..":"..name) end
        end,
        yield = function() return kernel.scheduler:yield() end,
        sleep = function(seconds) return kernel.scheduler:sleep(seconds) end
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
        failures = 0,
        failuresByMethod = {},
        windows = {},
        events = mailbox()
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
    for window in pairs(owner.windows) do window:close() end
    owner.windows={}
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
        if not self.running then return false,"kernel is stopping" end
        owner.enabled = true
        owner.failures=0 owner.failuresByMethod={}
        owner.starting = true
        owner.events = mailbox()
        local function start()
            local ok, err = pcall(function()
                if owner.definition.start then owner.definition.start(owner.context) end
            end)
            owner.starting = false
            if not ok then
                owner.enabled = false
                if self.scheduler then self.scheduler:cancelOwner(id) end
                if self.inputOwner==id or self.inputMode==id or (id=="storage" and self.inputMode=="restock") then
                    self.inputMode=nil self.inputOwner=nil
                end
                self:_dropOwned(owner)
                self:notify(id .. ": " .. tostring(err), self.config.theme.red)
                return false,err
            end
            if self.scheduler and owner.enabled then self:_startLogic(owner) self:_startSensor(owner) end
            return true
        end
        if self.scheduler then
            self.scheduler:spawn(id..":__start",start,{owner=id,priority=100+(owner.definition.priority or 100)})
        else local ok,err=start() if not ok then return false,err end end
    else
        owner.enabled = false
        owner.starting = false
        if self.scheduler then self.scheduler:cancelOwner(id) end
        if owner.definition.stop then pcall(owner.definition.stop, owner.context) end
        owner.events = mailbox()
        if self.inputOwner==id or self.inputMode==id or (id=="storage" and self.inputMode=="restock") then
            self.inputMode=nil self.inputOwner=nil
        end
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
    if not callback or not owner.enabled or owner.starting then return end
    local ok, result = pcall(callback, owner.context, ...)
    if ok then
        owner.failuresByMethod[method] = 0
        return result
    end
    local err = result
    owner.failuresByMethod[method] = (owner.failuresByMethod[method] or 0)+1
    owner.failures = owner.failuresByMethod[method]
    print(("[%s/%s] %s"):format(owner.definition.id, method, tostring(err)))
    if owner.failures >= 3 then
        self:notify(owner.definition.id .. " disabled after errors", self.config.theme.red)
        self:setEnabled(owner.definition.id, false)
    end
end

function Kernel:_loadApps()
    for _, moduleName in ipairs(self.config.modules) do require(moduleName) end
    -- Configs are preserved by the installer. Load the new built-in search
    -- on existing glasses without requiring a manual modules-list edit.
    if fs.exists("/m2os/apps/block_search.lua") then require("m2os.apps.block_search") end
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
    self.running=false
    if self.scheduler then self.scheduler:cancelAll() end
    self.inputMode=nil self.inputOwner=nil
    for index = #self.appOrder, 1, -1 do
        local owner = self.appOrder[index]
        local enabled=owner.enabled
        owner.enabled=false owner.starting=false
        if enabled and owner.definition.stop then pcall(owner.definition.stop, owner.context) end
        self:_dropOwned(owner)
        owner.enabled = false
    end
    pcall(self.overlay.update)
end

function Kernel:_startLogic(owner)
    if not self.scheduler or not self.running or not owner.enabled or owner.starting then return end
    if not owner.definition.logic and not owner.definition.onEvent then return end
    local interval=math.max(50,tonumber(owner.definition.logicIntervalMs) or 50)
    self.scheduler:spawn(owner.definition.id..":__logic",function()
        local nextAt,lastTick=0,util.epoch()
        while self.running and owner.enabled do
            for _=1,32 do
                local event=dequeue(owner.events)
                if not event then break end
                self:_invoke(owner,"onEvent",table.unpack(event,1,event.n or #event))
                if not self.running or not owner.enabled then return end
            end
            local now=util.epoch()
            if owner.definition.logic and now>=nextAt then
                self:_invoke(owner,"logic",now,(now-lastTick)/1000)
                if not self.running or not owner.enabled then return end
                lastTick=now nextAt=util.epoch()+interval
                self.scheduler:timer(interval/1000)
            end
            if owner.events.head<=owner.events.tail then self.scheduler:yield()
            else os.pullEventRaw() end
        end
    end,{owner=owner.definition.id,priority=100+(owner.definition.priority or 100)})
end

function Kernel:_startSensor(owner)
    if not self.scheduler or not self.running then return end
    local id=owner.definition.id..":__sensor"
    self.scheduler:cancel(id)
    if not owner.enabled or owner.starting or not owner.definition.poll then return end
    local interval=math.max(50,tonumber(owner.definition.pollIntervalMs) or 50)
    self.scheduler:spawn(id,function()
        local lastTick=util.epoch()
        while self.running and owner.enabled do
            local now=util.epoch()
            self:_invoke(owner,"poll",now,(now-lastTick)/1000)
            if not self.running or not owner.enabled then return end
            lastTick=now
            -- Schedule after completion, never catch up with overlapping scans.
            self.scheduler:sleep(interval/1000)
        end
    end,{owner=owner.definition.id,priority=10000+(owner.definition.priority or 100)})
end

function Kernel:_dispatchInput(event)
    local lifecycle=event[1]=="keyboard_open" or event[1]=="keyboard_close"
    if event[1]=="keyboard_open" and self.inputMode then
        for _,owner in ipairs(self.appOrder) do self:_invoke(owner,"onEvent","keyboard_close") end
        self.inputMode=nil self.inputOwner=nil
    end
    local current=not lifecycle and self.inputMode and self.apps[self.inputOwner or self.inputMode] or nil
    if current and self:_invoke(current,"onEvent",table.unpack(event,1,event.n or #event)) then return end
    if not self.running then return end
    for _,owner in ipairs(self.appOrder) do
        if owner~=current then
            local consumed=self:_invoke(owner,"onEvent",table.unpack(event,1,event.n or #event))
            if not self.running then return end
            if consumed and not lifecycle then break end
        end
    end
    if event[1]=="keyboard_close" then self.inputMode=nil self.inputOwner=nil end
end

function Kernel:_uiLoop()
    local lastTick=util.epoch()
    local nextAt=lastTick+50
    self.scheduler:timer(0.05)
    while self.running do
        local input=false
        for _=1,64 do
            local event=dequeue(self.inputEvents)
            if not event then break end
            input=true self:_dispatchInput(event)
            if not self.running then return end
        end
        local now=util.epoch()
        if now>=nextAt then
            local oldWidth,oldHeight=self.width,self.height
            self:_measure()
            if oldWidth~=self.width or oldHeight~=self.height then
                for _,owner in ipairs(self.appOrder) do
                    for window in pairs(owner.windows) do window:resize() end
                    self:_invoke(owner,"resize",self.width,self.height)
                    if not self.running then return end
                end
            end
            for _,owner in ipairs(self.appOrder) do
                self:_invoke(owner,"update",now,(now-lastTick)/1000)
                if owner.enabled and not owner.starting then
                    for window in pairs(owner.windows) do window:update(now) end
                end
                if not self.running then return end
            end
            lastTick=now nextAt=util.epoch()+50
            self.scheduler:timer(0.05)
            self.overlay.update()
        elseif input then
            -- Input feedback does not wait for the next frame or a sensor.
            self.overlay.update()
        end
        if self.inputEvents.head<=self.inputEvents.tail then self.scheduler:yield()
        else os.pullEventRaw() end
    end
end

function Kernel:_startRuntime()
    self.overlay.setAutoUpdate(false)
    self.inputEvents=mailbox()
    self.scheduler=Scheduler.new(function(task,err)
        self:notify("Task "..task.id..": "..tostring(err),self.config.theme.red)
        if task.owner=="__kernel" then self.running=false self.scheduler:cancelAll()
        else self:setEnabled(task.owner,false) end
    end)
    self:_loadApps()
    self.scheduler:spawn("__gui",function() self:_uiLoop() end,{owner="__kernel",priority=0})
    self:_startApps()
    self:notify(self.config.name .. " " .. self.config.version .. " online (async)", self.config.theme.green)
    self.scheduler:step()
end

function Kernel:_stepRuntime(event)
    if event[1]=="terminate" then
        self.running=false self.scheduler:cancelAll() return
    end
    if INPUT[event[1]] then enqueue(self.inputEvents,event)
    elseif event[1]~="task_complete" and not self.scheduler:isInternal(event) then
        for _,owner in ipairs(self.appOrder) do
            if owner.enabled and owner.definition.onEvent then enqueue(owner.events,event) end
        end
    end
    self.scheduler:step(event)
end

function Kernel:loop()
    self:_startRuntime()
    while self.running do
        self:_stepRuntime(table.pack(os.pullEventRaw()))
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
