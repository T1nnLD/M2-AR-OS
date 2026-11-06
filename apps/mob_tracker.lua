local api = require("m2os.api")

local app = {
    id = "mob_tracker",
    name = "Threat Tracker",
    menuLabel = "THREAT BOXES",
    menuOrder = 20,
    priority = 40,
    defaultEnabled = true
}

local detector
local markers = {}
local nextScan = 0
local warned = false
local scanRange
local scanInterval
local lastScanWarning

local function scanWarning(ctx, message)
    if lastScanWarning == message then return end
    lastScanWarning = message
    print("[Threat Boxes] " .. message)
    ctx.notify("Threat Boxes: " .. message, ctx.config.theme.amber)
end

local function configureScan(ctx)
    scanRange = math.max(1, math.floor(tonumber(ctx.config.tracker.range) or 16))
    scanInterval = math.max(100, tonumber(ctx.config.tracker.intervalMs) or 2100)
    if type(detector.getConfiguration) ~= "function" then return end
    local ok, config = pcall(detector.getConfiguration)
    if not ok or type(config) ~= "table" or type(config.operations) ~= "table" then return end
    for key, operation in pairs(config.operations) do
        local name = tostring(key):lower():gsub("[^a-z]", "")
        if name == "scanentities" and type(operation) == "table" then
            -- Glasses have no fuel ability: paid scans fail even below the
            -- maximum radius. Use the server's free radius and cooldown.
            local free = tonumber(operation.maxFreeRadius)
            local maximum = tonumber(operation.maxCostRadius)
            if free and free >= 1 then scanRange = math.min(scanRange, math.floor(free)) end
            if maximum and maximum >= 1 then scanRange = math.min(scanRange, math.floor(maximum)) end
            scanInterval = math.max(scanInterval, (tonumber(operation.defaultCooldown) or 0) + 50)
            if scanRange < (tonumber(ctx.config.tracker.range) or 16) then
                scanWarning(ctx, "Server scan range: " .. scanRange .. " blocks")
            end
            return
        end
    end
end

local DIMENSIONS = {
    ["minecraft:spider"] = { 1.4, 0.9 },
    ["minecraft:cave_spider"] = { 0.8, 0.5 },
    ["minecraft:enderman"] = { 0.8, 2.9 },
    ["minecraft:creeper"] = { 0.7, 1.7 },
    ["minecraft:phantom"] = { 1.5, 0.7 },
    ["minecraft:guardian"] = { 1.3, 1.3 },
    ["minecraft:elder_guardian"] = { 2.0, 2.0 },
    ["minecraft:ghast"] = { 4.0, 4.0 },
    ["minecraft:silverfish"] = { 0.5, 0.35 },
    ["minecraft:endermite"] = { 0.5, 0.35 }
}

local function findDetector()
    return peripheral.find("environment_detector")
        or peripheral.find("environmentDetector")
end

local function removeMarker(ctx, marker)
    for _, object in ipairs(marker.parts) do ctx.ui.remove(object) end
    ctx.ui.remove(marker.beacon)
end

local function clear(ctx)
    for key, marker in pairs(markers) do
        removeMarker(ctx, marker)
        markers[key] = nil
    end
end

local function createMarker(ctx)
    local marker = { parts = {} }
    local thickness = ctx.config.tracker.boxThickness
    for index = 1, 24 do
        marker.parts[index] = ctx.ui.raw("Box", {
            gui = false, x = 0, y = 0, z = 0,
            sizeX = thickness, sizeY = thickness, sizeZ = thickness,
            color = ctx.config.theme.red, opacity = 0.92,
            culling = false, depthTest = false, depthMask = false
        })
    end
    marker.beacon = ctx.ui.raw("Box", {
        gui = false, x = 0, y = 0, z = 0,
        rotX = 45, rotY = 45, rotZ = 45,
        sizeX = 0.16, sizeY = 0.16, sizeZ = 0.16,
        color = ctx.config.theme.red, opacity = 1,
        culling = false, depthTest = false, depthMask = false
    })
    return marker
end

local function dimensions(entity, config)
    local overrides = type(config.entitySizes) == "table" and config.entitySizes or {}
    local known = overrides[entity.name] or DIMENSIONS[entity.name]
    local width, height
    if type(known) == "table" then
        width, height = tonumber(known.width or known[1]), tonumber(known.height or known[2])
        if width and height and width > 0 and height > 0 then
            if entity.baby then return width * 0.65, height * 0.65 end
            return width, height
        end
    end

    -- AP 0.8.2a exposes eyeHeight but not the entity's bounding box. Use the
    -- current eye height for unknown registry IDs, including modded mobs.
    -- It already reflects baby size, so do not scale babies a second time.
    local eyeHeight = tonumber(entity.eyeHeight)
    if eyeHeight and eyeHeight > 0 then
        height = math.max(0.2, eyeHeight * 1.15)
    else
        height = entity.baby and 0.9 or 1.8
    end
    width = math.max(0.2, height * 0.46)
    return width, height
end

local function isTarget(entity, config)
    if type(entity) ~= "table" then return false end
    -- scanEntities normally returns living entities. health/maxHealth also
    -- make this safe for providers which include items or projectiles.
    if not tonumber(entity.health) or tonumber(entity.health) <= 0 then return false end
    if entity.name == "minecraft:player" or entity.name == "minecraft:armor_stand"
            or entity.isPlayer == true then return false end
    if not tonumber(entity.x) or not tonumber(entity.y) or not tonumber(entity.z) then
        return false
    end
    -- The old aggressiveOnly option is deliberately superseded: existing
    -- installations keep config.lua on update and should get universal boxes.
    local mode = config.targetMode or "all"
    if mode == "aggressive" then return entity.aggressive == true end
    if mode == "hostile" then
        return entity.aggressive == true or entity.category == "monster"
    end
    return true
end

local function positionMarker(ctx, marker, x, y, z, width, height)
    local thickness = ctx.config.tracker.boxThickness
    local half = width / 2 + 0.12
    local x0, x1, z0, z1 = x - half, x + half, z - half, z + half
    local y0, y1 = y + 0.04, y + height + 0.12
    local sx = math.min((x1 - x0) * 0.30, 0.42)
    local sy = math.min((y1 - y0) * 0.24, 0.42)
    local sz = sx
    local index = 1

    local function set(px, py, pz, dx, dy, dz)
        local part = marker.parts[index]
        index = index + 1
        part.setPos(px, py, pz)
        part.setSizes(dx, dy, dz)
    end

    for _, py in ipairs({ y0, y1 }) do
        for _, pz in ipairs({ z0, z1 }) do
            set(x0 + sx / 2, py, pz, sx, thickness, thickness)
            set(x1 - sx / 2, py, pz, sx, thickness, thickness)
        end
    end
    for _, px in ipairs({ x0, x1 }) do
        for _, pz in ipairs({ z0, z1 }) do
            set(px, y0 + sy / 2, pz, thickness, sy, thickness)
            set(px, y1 - sy / 2, pz, thickness, sy, thickness)
        end
    end
    for _, px in ipairs({ x0, x1 }) do
        for _, py in ipairs({ y0, y1 }) do
            set(px, py, z0 + sz / 2, thickness, thickness, sz)
            set(px, py, z1 - sz / 2, thickness, thickness, sz)
        end
    end
    marker.beacon.setPos(x, y1 + 0.28, z)
end

local function scan(ctx, eyeX, eyeY, eyeZ)
    if not detector then
        detector = findDetector()
        if detector then configureScan(ctx) end
    end
    if not detector then
        clear(ctx)
        if not warned then
            warned = true
            ctx.notify("Environment Detector not found", ctx.config.theme.amber)
        end
        return
    end

    local ok, entities, reason = pcall(detector.scanEntities, scanRange, true)
    if not ok or type(entities) ~= "table" then
        local message = tostring(ok and (reason or "scan returned no data") or entities)
        local lower = message:lower()
        if lower:find("cooldown", 1, true) then
            -- Cooldown is temporary; retain the last successful markers.
            nextScan = math.max(nextScan, ctx.system.now and ctx.system.now() + scanInterval or nextScan)
        else
            clear(ctx)
            scanWarning(ctx, message)
            if lower:find("radius", 1, true) or lower:find("fuel", 1, true) then
                -- Compatibility fallback when getConfiguration is absent.
                scanRange = math.max(1, math.floor(scanRange / 2))
            elseif not ok then
                detector = nil
            end
        end
        return
    end

    local targets = {}
    for _, entity in pairs(entities) do
        if isTarget(entity, ctx.config.tracker) then
            entity.x, entity.y, entity.z = tonumber(entity.x), tonumber(entity.y), tonumber(entity.z)
            entity._distanceSquared = entity.x * entity.x + entity.y * entity.y + entity.z * entity.z
            targets[#targets + 1] = entity
        end
    end
    table.sort(targets, function(a, b) return a._distanceSquared < b._distanceSquared end)

    local visible = {}
    for index = 1, math.min(ctx.config.tracker.maxTargets, #targets) do
        local entity = targets[index]
        local key = entity.uuid or tostring(entity.id or index)
        local marker = markers[key]
        if not marker then
            marker = createMarker(ctx)
            markers[key] = marker
        end
        local width, height = dimensions(entity, ctx.config.tracker)
        positionMarker(ctx, marker, eyeX + entity.x, eyeY + entity.y,
            eyeZ + entity.z, width, height)
        visible[key] = true
    end
    for key, marker in pairs(markers) do
        if not visible[key] then
            removeMarker(ctx, marker)
            markers[key] = nil
        end
    end
end

function app.start()
    detector = nil
    warned = false
    nextScan = 0
    scanRange = nil
    scanInterval = nil
    lastScanWarning = nil
end

function app.update(ctx, now)
    if now < nextScan then return end
    local x, y, z = ctx.system.getEyePosition()
    if x and y and z then scan(ctx, x, y, z) end
    nextScan = math.max(nextScan, now + (scanInterval or 2100))
end

function app.stop(ctx)
    clear(ctx)
    detector = nil
end

api.registerApp(app)
return app
