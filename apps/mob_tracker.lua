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

local function dimensions(entity)
    local known = DIMENSIONS[entity.name]
    local width, height
    if known then
        width, height = known[1], known[2]
    else
        height = math.max(0.6, (entity.eyeHeight or 1.4) + 0.25)
        width = math.max(0.55, math.min(1.1, height * 0.46))
    end
    if entity.baby then return width * 0.65, height * 0.65 end
    return width, height
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
    detector = detector or findDetector()
    if not detector then
        clear(ctx)
        if not warned then
            warned = true
            ctx.notify("Environment Detector not found", ctx.config.theme.amber)
        end
        return
    end

    local ok, entities = pcall(detector.scanEntities, ctx.config.tracker.range, true)
    if not ok then
        detector = nil
        clear(ctx)
        return
    end
    if type(entities) ~= "table" then return end

    local targets = {}
    for _, entity in pairs(entities) do
        local hostile
        if ctx.config.tracker.aggressiveOnly then
            hostile = entity.aggressive == true
        else
            hostile = entity.aggressive == true or entity.category == "monster"
        end
        if hostile and entity.x and entity.y and entity.z
                and (not entity.health or entity.health > 0) then
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
        local width, height = dimensions(entity)
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
end

function app.update(ctx, now)
    if now < nextScan then return end
    nextScan = now + ctx.config.tracker.intervalMs
    local x, y, z = ctx.system.getEyePosition()
    if x and y and z then scan(ctx, x, y, z) end
end

function app.stop(ctx)
    clear(ctx)
    detector = nil
end

api.registerApp(app)
return app
