local util = {}

function util.epoch()
    return os.epoch("utc")
end

function util.clamp(value, low, high)
    return math.max(low, math.min(high, value))
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
