local util = {}

function util.epoch()
    return os.epoch("utc")
end

function util.clamp(value, low, high)
    return math.max(low, math.min(high, value))
end

-- Return the opaque RGB colour produced by alpha-compositing foreground over
-- background. This is useful for overlay primitives whose own transparency
-- would otherwise sample whatever happens to be rendered below them.
function util.blendColor(foreground, background, alpha)
    foreground = tonumber(foreground) or 0
    background = tonumber(background) or 0
    alpha = util.clamp(tonumber(alpha) or 0, 0, 1)
    local function channel(color, shift)
        return math.floor(color / shift) % 256
    end
    local function mix(front, back)
        return math.floor(front * alpha + back * (1 - alpha) + 0.5)
    end
    local red = mix(channel(foreground, 65536), channel(background, 65536))
    local green = mix(channel(foreground, 256), channel(background, 256))
    local blue = mix(channel(foreground, 1), channel(background, 1))
    return red * 65536 + green * 256 + blue
end

-- AP 0.8.2a renders Text after Rectangle, Item, Texture and Circle. Build the
-- round pointer from font circles so it cannot disappear underneath a panel.
-- Both storage and the radial menu call these helpers and therefore use the
-- same geometry, colours and renderer.
local CURSOR_TEXT_LAYERS = {
    { key = "glow", glyph = "●", size = 1.75, y = -7.875 },
    -- Unicode Support renders the hollow-circle glyph almost square. This
    -- bullseye uses the round glyph which was already verified in-game; the
    -- purple dot below covers its white centre.
    { key = "ring", glyph = "◉", size = 1.15, y = -5.175 },
    { key = "dot", glyph = "●", size = 0.43, y = -1.935 }
}

function util.createTopCursor(ui, x, y, z, theme)
    local surface = util.blendColor(theme.blue, theme.background, 0.12)
    local colours = {
        glow = util.blendColor(theme.purple, surface, 0.18),
        ring = theme.white,
        dot = theme.purple
    }
    local cursor = { baseZ = z }
    for index, layer in ipairs(CURSOR_TEXT_LAYERS) do
        cursor[layer.key] = ui.raw("Text", {
            gui = true, x = x, y = y + layer.y, z = z + index - 1,
            content = layer.glyph, color = colours[layer.key], opacity = 1,
            fontSize = layer.size, shadow = false, center = true,
            culling = false, depthTest = false
        })
    end
    return cursor
end

function util.moveTopCursor(cursor, x, y, z)
    if type(cursor) ~= "table" then return end
    z = tonumber(z) or cursor.baseZ or 0
    cursor.baseZ = z
    for index, layer in ipairs(CURSOR_TEXT_LAYERS) do
        local object = cursor[layer.key]
        if object and type(object.setPos) == "function" then
            pcall(object.setPos, x, y + layer.y, z + index - 1)
        end
    end
end

function util.readTable(path, fallback)
    if not fs.exists(path) or fs.isDir(path) then
        return fallback
    end
    local handle = fs.open(path, "r")
    if not handle then return fallback end
    local raw = handle.readAll()
    handle.close()
    local ok, value = pcall(textutils.unserialize, raw)
    if ok and type(value) == "table" then return value end
    return fallback
end

function util.writeTable(path, value)
    local handle = fs.open(path, "w")
    if not handle then return false, "cannot open " .. path end
    handle.write(textutils.serialize(value))
    handle.close()
    return true
end

function util.module(name)
    if not smartglasses or not smartglasses.modules then return nil end
    return smartglasses.modules[name]
        or smartglasses.modules["advancedperipherals:" .. name]
end

function util.findWirelessModem()
    for _, name in ipairs(peripheral.getNames()) do
        if peripheral.hasType(name, "modem") then
            local modem = peripheral.wrap(name)
            local ok, wireless = pcall(modem.isWireless)
            if ok and wireless then return name, modem end
        end
    end
    return nil
end

function util.itemLabel(item)
    if type(item) ~= "table" then return tostring(item) end
    local label = item.displayName or item.label or item.name or "unknown"
    label = label:gsub("^.+:", "")
    label = label:gsub("_", " ")
    return label
end

local function utf8CharacterStart(value, index)
    index = math.max(1, math.min(tonumber(index) or #value, #value))
    while index > 1 do
        local byte = value:byte(index)
        if not byte or byte < 0x80 or byte >= 0xC0 then break end
        index = index - 1
    end
    return index
end

function util.utf8Length(value)
    value = tostring(value or "")
    local length = 0
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 0x80 or byte >= 0xC0 then length = length + 1 end
    end
    return length
end

function util.utf8Sub(value, first, last)
    value = tostring(value or "")
    local length = util.utf8Length(value)
    first = tonumber(first) or 1
    last = tonumber(last) or length
    if first < 0 then first = length + first + 1 end
    if last < 0 then last = length + last + 1 end
    first = math.max(1, first)
    last = math.min(length, last)
    if first > last then return "" end
    local character, byteFirst, byteLast = 0, nil, #value
    for index = 1, #value do
        local byte = value:byte(index)
        if byte < 0x80 or byte >= 0xC0 then
            character = character + 1
            if character == first then byteFirst = index end
            if character == last + 1 then byteLast = index - 1 break end
        end
    end
    return byteFirst and value:sub(byteFirst, byteLast) or ""
end

function util.utf8Backspace(value)
    value = tostring(value or "")
    if value == "" then return value end
    return value:sub(1, utf8CharacterStart(value, #value) - 1)
end

function util.short(value, maxLength)
    value = tostring(value or "")
    maxLength = maxLength or 28
    if util.utf8Length(value) <= maxLength then return value end
    return util.utf8Sub(value, 1, maxLength - 1) .. "~"
end

function util.copy(value)
    if type(value) ~= "table" then return value end
    local out = {}
    for key, child in pairs(value) do out[key] = util.copy(child) end
    return out
end

function util.findPeripheral(methods, preferredTypes)
    for _, kind in ipairs(preferredTypes or {}) do
        local found = peripheral.find(kind)
        if found then return found, kind end
    end
    for _, name in ipairs(peripheral.getNames()) do
        local wrapped = peripheral.wrap(name)
        local valid = true
        for _, method in ipairs(methods or {}) do
            if type(wrapped[method]) ~= "function" then valid = false break end
        end
        if valid then return wrapped, name end
    end
    return nil
end

return util
