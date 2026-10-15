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

function util.short(value, maxLength)
    value = tostring(value or "")
    maxLength = maxLength or 28
    if #value <= maxLength then return value end
    return value:sub(1, maxLength - 1) .. "~"
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
