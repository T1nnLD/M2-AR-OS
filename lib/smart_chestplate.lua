-- AP 0.8.2a native API adapter. No operations are performed at module load.
local Chest = {}
Chest.__index = Chest

local ERRORS = {
    SMART_CHEST_NOT_EQUIPPED = "Умный нагрудник не надет или отключён сервером",
    HAND_DOES_NOT_EXISTS = "Такой руки нет",
    ACTION_CONFLICT = "Рука занята — повтори команду",
    TOOL_REQUIRED = "В руке нужен инструмент"
}

function Chest.new(native)
    return setmetatable({ native = native or {} }, Chest)
end

function Chest:call(method, ...)
    if type(self.native[method]) ~= "function" then
        return false, "API недоступен: " .. method
    end
    local values = table.pack(pcall(self.native[method], ...))
    if not values[1] then return false, tostring(values[2]) end
    if values[2] == nil or values[2] == false then
        local reason = tostring(values[3] or "Действие не выполнено")
        return false, ERRORS[reason] or reason
    end
    return true, table.unpack(values, 2, values.n)
end

local function validHand(hand)
    return type(hand) == "number" and hand % 1 == 0 and hand >= 1 and hand <= 5
end

function Chest:probe()
    local ok, equipped, count = self:call("pingSmartChest")
    -- ping returns true, slot count, while call adds its own success flag.
    if not ok then return false, equipped end
    return true, tonumber(count) or 5
end

function Chest:position(hand)
    if not validHand(hand) then return false, "Номер руки должен быть от 1 до 5" end
    local ok, x, y, z, pitch, yaw = self:call("smartHandPos", hand)
    if not ok then return false, x end
    if not tonumber(x) or not tonumber(y) or not tonumber(z) then
        return false, "API вернул неверные координаты руки"
    end
    return true, { x = tonumber(x), y = tonumber(y), z = tonumber(z),
        pitch = tonumber(pitch) or 0, yaw = tonumber(yaw) or 0 }
end

function Chest:move(hand, position)
    if not validHand(hand) then return false, "Номер руки должен быть от 1 до 5" end
    local out = {}
    for _, key in ipairs({ "x", "y", "z", "pitch", "yaw" }) do
        local value = tonumber(position[key])
        if not value or value ~= value or math.abs(value) == math.huge then
            return false, "Неверное значение " .. key
        end
        out[key] = value
    end
    if out.x * out.x + out.y * out.y + out.z * out.z > 100.00001 then
        return false, "Рука не может удалиться больше чем на 10 блоков"
    end
    out.pitch = math.max(-90, math.min(90, out.pitch))
    out.yaw = (out.yaw + 180) % 360 - 180
    -- Do not use wrapSmartHand.setPos: the AP 0.8.2a Lua wrapper passes x
    -- instead of the assembled coordinate table.
    return self:call("smartHandMove", hand, out)
end

function Chest:transfer(hand, slot, load)
    if not validHand(hand) then return false, "Номер руки должен быть от 1 до 5" end
    local filter = { count = 64 }
    local method
    if load then
        if type(slot) ~= "number" or slot % 1 ~= 0 or slot < 1 or slot > 36 then
            return false, "Выбери слот инвентаря 1–36"
        end
        filter.fromSlot, filter.toSlot = slot, hand
        method = "smartChestImportItem"
    else
        filter.fromSlot = hand
        method = "smartChestExportItem"
    end
    local ok, moved = self:call(method, filter)
    if not ok then return false, moved end
    moved = tonumber(moved)
    if not moved or moved <= 0 then
        return false, load and "Не перенесено: слот пуст, рука заполнена или предмет несовместим"
            or "Не перенесено: рука пуста или инвентарь заполнен"
    end
    return true, moved
end

function Chest:action(hand, action)
    if not validHand(hand) then return false, "Номер руки должен быть от 1 до 5" end
    local methods = { attack = "smartHandAttack", dig = "smartHandDig", use = "smartHandUse",
        suck = "smartHandSuckItem", drop = "smartHandDropItem" }
    local method = methods[action]
    if not method then return false, "Неизвестное действие" end
    if action == "drop" or action == "suck" then
        return self:call(method, hand, 64)
    end
    return self:call(method, hand, { sneak = false })
end

function Chest:inventory()
    -- Despite the method name, this version returns the PLAYER inventory,
    -- not the five chestplate slots. Use it only for source-slot selection.
    local ok, value = self:call("smartChestList")
    if not ok then return false, value end
    if type(value) ~= "table" then return false, "Неверный ответ инвентаря" end
    return true, value
end

return Chest
