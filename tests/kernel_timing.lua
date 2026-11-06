-- Run from the repository root: lua tests/kernel_timing.lua
table.insert(package.searchers or package.loaders, 1, function(name)
    if name:match("^m2os%.") then
        local path = name:gsub("^m2os%.", ""):gsub("%.", "/") .. ".lua"
        local chunk = loadfile(path)
        if chunk then return chunk, path end
    end
end)
local Kernel = require("m2os.kernel")

local function scenario(slowUpdate)
    local now, timerId, eventIndex = 0, 0, 0
    local timers = {}
    local frames, boxUpdates, menuReady = 0, 0, false
    local menuDrawAt
    os.epoch = function() return now end
    os.startTimer = function(seconds)
        timerId = timerId + 1
        timers[timerId] = now + seconds * 1000
        return timerId
    end
    os.cancelTimer = function(id) timers[id] = nil end
    os.pullEventRaw = function()
        eventIndex = eventIndex + 1
        if eventIndex == 1 then now = 10 return "key", "native-call" end
        if eventIndex == 2 then now = now + 10 return "keyboard_close" end
        if eventIndex == 3 then now = now + 10 return "keyboard_open" end
        if eventIndex <= 8 and timers[timerId] then
            now = timers[timerId]
            timers[timerId] = nil
            return "timer", timerId
        end
        return "terminate"
    end
    local app = {
        enabled = true, failures = 0, context = {},
        definition = {
            id = "box-and-menu-test",
            update = function()
                boxUpdates = boxUpdates + 1
                if slowUpdate then now = now + 80 end
                if menuDrawAt and now >= menuDrawAt then menuReady = true end
            end
        }
    }
    local kernel = setmetatable({
        running = true, config = {name="test",version="test",theme={green=0}}, width = 800,height = 500,
        appOrder = {app}, overlay = {
            setAutoUpdate = function() end,
            update = function() frames = frames + 1 end
        },
        _loadApps = function() end, _startApps = function() end,
        _measure = function() end, notify = function() end, _shutdown = function() end,
        _dispatchEvent = function(_, event)
            if event[1] == "key" then
                -- An AP call waits for task_complete. During that wait the
                -- pending frame timer fires and is not returned to this loop.
                now = now + 110
                timers[1] = nil
            elseif event[1] == "keyboard_open" then
                menuDrawAt = now + 180
            end
        end
    }, Kernel)
    kernel:loop()
    assert(boxUpdates >= 5 and frames >= 5,
        "lost timer during a native call must not stop box updates and overlay frames")
    assert(menuReady, "radial menu must appear after the native call and a new open event")
    assert(timerId >= 6, "frame timer must be rearmed after a native call swallows its event")
end

scenario(false)
scenario(true)
print("kernel lost-timer recovery tests: OK")
