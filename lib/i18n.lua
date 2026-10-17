local i18n = {}

local ok, language = pcall(require, "m2os.lang.ru_ru")
if not ok or type(language) ~= "table" then language = {} end
language.items = type(language.items) == "table" and language.items or {}
language.enchantments = type(language.enchantments) == "table"
    and language.enchantments or {}
language.mods = type(language.mods) == "table" and language.mods or {}

function i18n.lower(value)
    local result = tostring(value or ""):lower()
    -- UTF-8 Russian case folding without relying on a locale-aware string
    -- library (Lua's built-in string.lower only handles ASCII).
    result = result:gsub("\208\129", "\209\145") -- Ё -> ё
    result = result:gsub("\208([\144-\159])", function(second)
        return "\208" .. string.char(second:byte() + 32) -- А-П -> а-п
    end)
    result = result:gsub("\208([\160-\175])", function(second)
        return "\209" .. string.char(second:byte() - 32) -- Р-Я -> р-я
    end)
    return result
end

function i18n.fold(value)
    local result = i18n.lower(value)
    result = result:gsub("ё", "е")
    result = result:gsub("§.", "")
    result = result:gsub("[_%.%-/]+", " ")
    result = result:gsub("%s+", " ")
    return result:match("^%s*(.-)%s*$") or result
end

local function compact(value)
    return i18n.fold(value):gsub("[^%w\128-\255]+", "")
end

local function translated(entry)
    if type(entry) == "string" then return entry, nil end
    if type(entry) ~= "table" then return nil, nil end
    return entry[1] or entry.ru, entry[2] or entry.en
end

function i18n.itemNames(registryName, fallback)
    local russian, english = translated(language.items[tostring(registryName or "")])
    return russian, english or fallback
end

function i18n.enchantmentNames(registryName, fallback)
    local russian, english = translated(
        language.enchantments[tostring(registryName or "")])
    return russian, english or fallback
end

local function unreadable(value)
    return tostring(value or ""):find("%?%?") ~= nil
end

local function chooseLocalized(russian, english, fallback)
    fallback = tostring(fallback or "")
    if not russian or russian == "" then return fallback end
    if fallback == "" or unreadable(fallback) then return russian end
    local folded = i18n.fold(fallback)
    if folded == i18n.fold(russian)
            or (english and folded == i18n.fold(english)) then
        return russian
    end
    -- Preserve custom anvil names while still exposing both translated aliases
    -- to search through localizedName and englishName.
    return fallback
end

local ROMAN_LEVELS = {
    [1] = "I", [2] = "II", [3] = "III", [4] = "IV", [5] = "V",
    [6] = "VI", [7] = "VII", [8] = "VIII", [9] = "IX", [10] = "X"
}

function i18n.localizeEnchantment(enchantment)
    enchantment = type(enchantment) == "table" and enchantment or {}
    local russian, english = i18n.enchantmentNames(
        enchantment.name, enchantment.displayName)
    local result = {}
    for key, value in pairs(enchantment) do result[key] = value end
    result.localizedName = russian
    result.englishName = english
    if russian and russian ~= "" then
        local level = tonumber(enchantment.level) or 1
        result.displayName = russian .. " "
            .. (ROMAN_LEVELS[level] or tostring(level))
    else
        result.displayName = chooseLocalized(russian, english,
            enchantment.displayName)
    end
    return result
end

function i18n.localizeItem(item)
    item = type(item) == "table" and item or {}
    local russian, english = i18n.itemNames(item.name, item.displayName)
    local result = {}
    for key, value in pairs(item) do result[key] = value end
    result.localizedName = russian
    result.englishName = english
    result.displayName = chooseLocalized(russian, english, item.displayName)
    local namespace = tostring(item.name or ""):match("^([^:]+):") or ""
    result.mod = namespace
    result.modName = language.mods[namespace] or namespace
    result.enchantments = {}
    for _, enchantment in ipairs(type(item.enchantments) == "table"
            and item.enchantments or {}) do
        result.enchantments[#result.enchantments + 1]
            = i18n.localizeEnchantment(enchantment)
    end
    return result
end

local function contains(haystack, needle)
    if needle == "" then return true end
    if haystack:find(needle, 1, true) then return true end
    local compactNeedle = compact(needle)
    return compactNeedle ~= "" and compact(haystack):find(
        compactNeedle, 1, true) ~= nil
end

function i18n.matchesItem(item, query)
    query = i18n.fold(query)
    if query == "" then return true end
    local wholeModQuery = query:match("^@(.+)$")
    if type(item) ~= "table" or item.mod == nil then
        item = i18n.localizeItem(item)
    end
    local nameParts, modParts = {}, {}
    for token in query:gmatch("%S+") do
        if token:sub(1, 1) == "@" then
            local value = token:sub(2)
            if value ~= "" then modParts[#modParts + 1] = value end
        else
            nameParts[#nameParts + 1] = token
        end
    end
    local itemHaystack = i18n.fold(table.concat({
        tostring(item.name or ""), tostring(item.displayName or ""),
        tostring(item.localizedName or ""), tostring(item.englishName or "")
    }, " "))
    for _, enchantment in ipairs(item.enchantments or {}) do
        itemHaystack = itemHaystack .. " " .. i18n.fold(table.concat({
            tostring(enchantment.name or ""),
            tostring(enchantment.displayName or ""),
            tostring(enchantment.localizedName or ""),
            tostring(enchantment.englishName or "")
        }, " "))
    end
    local modHaystack = i18n.fold(table.concat({
        tostring(item.mod or ""), tostring(item.modName or "")
    }, " "))
    -- Allow friendly mod names containing spaces, for example
    -- "@Farmer's Delight". If the whole suffix is not a mod name, fall back
    -- to the composable form "@create mechanical arm".
    if wholeModQuery and contains(modHaystack, wholeModQuery) then return true end
    for _, part in ipairs(nameParts) do
        if not contains(itemHaystack, part) then return false end
    end
    for _, part in ipairs(modParts) do
        if not contains(modHaystack, part) then return false end
    end
    return true
end

return i18n
