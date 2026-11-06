local args = { ... }

if args[1] == "help" or args[1] == "--help" then
    print("M2OS HUD")
    print("  m2os        start the glasses OS")
    print("  m2os tracker  diagnose mob detection")
    print("  m2ctl help  storage command line client")
    print("  m2os_server start the Create storage bridge")
    return
end

if args[1] == "tracker" then
    local config = require("m2os.config")
    local util = require("m2os.lib.util")
    local state = util.readTable(config.stateFile or "/m2os-state.cfg", {})
    print("THREAT BOXES DIAGNOSTICS")
    print("Enabled: " .. tostring(not (state.enabled and state.enabled.mob_tracker == false)))
    local detector = peripheral.find("environment_detector") or peripheral.find("environmentDetector")
    if not detector then print("Environment Detector: NOT FOUND") return end
    print("Environment Detector: FOUND")
    local range = 8
    if type(detector.getConfiguration) == "function" then
        local ok, data = pcall(detector.getConfiguration)
        if ok and type(data) == "table" and type(data.operations) == "table" then
            for key, operation in pairs(data.operations) do
                if tostring(key):lower():gsub("[^a-z]", "") == "scanentities"
                        and type(operation) == "table" then
                    print("Server free radius: " .. tostring(operation.maxFreeRadius))
                    print("Server cooldown ms: " .. tostring(operation.defaultCooldown))
                    range = math.max(1, math.min(range, tonumber(operation.maxFreeRadius) or range))
                end
            end
        end
    end
    local ok, entities, reason = pcall(detector.scanEntities, math.floor(range), true)
    if not ok or type(entities) ~= "table" then
        print("Scan failed: " .. tostring(ok and reason or entities))
        return
    end
    local count, zombies = 0, 0
    for _, entity in pairs(entities) do
        if type(entity) == "table" then
            count = count + 1
            if tostring(entity.name):find("zombie", 1, true) then
                zombies = zombies + 1
                print(tostring(entity.name) .. " hp=" .. tostring(entity.health))
                print(("xyz: %s %s %s"):format(tostring(entity.x), tostring(entity.y), tostring(entity.z)))
            end
        end
    end
    print(("Entities within %d blocks: %d; zombies: %d"):format(range, count, zombies))
    return
end

local Kernel = require("m2os.kernel")
local config = require("m2os.config")

Kernel.run(config)
