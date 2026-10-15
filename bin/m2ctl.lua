local util = require("m2os.lib.util")
local config = require("m2os.config").storage
local args = { ... }

local function usage()
    print("M2OS Create storage client")
    print("  m2ctl ping")
    print("  m2ctl stock [search]")
    print("  m2ctl take <minecraft:item> [count]")
    print("  m2ctl put <minecraft:item> [count]")
    print("  m2ctl craft <minecraft:item> [count]")
end

if not args[1] or args[1] == "help" then usage() return end

local command = args[1]:lower()
if (command == "take" or command == "withdraw" or command == "put"
        or command == "deposit" or command == "craft") and not args[2] then
    usage()
    return
end

local modemName = util.findWirelessModem()
if not modemName then error("Wireless/Ender Modem not found", 0) end
local wasOpen = rednet.isOpen(modemName)
if not wasOpen then rednet.open(modemName) end

local serverId = config.serverId
if not serverId then
    rednet.broadcast({ kind = "discover", key = config.sharedKey }, config.protocol)
    local deadline = os.epoch("utc") + 3000
    while os.epoch("utc") < deadline do
        local sender, message = rednet.receive(config.protocol, 0.5)
        if sender and type(message) == "table" and message.kind == "hello"
                and message.key == config.sharedKey then
            serverId = sender
            break
        end
    end
end
if not serverId then
    if not wasOpen then rednet.close(modemName) end
    error("M2OS storage server not found", 0)
end

local operation, payload
if command == "ping" then
    operation, payload = "ping", {}
elseif command == "stock" or command == "find" then
    operation, payload = "stock", { query = args[2] or "", limit = 256 }
elseif command == "take" or command == "withdraw" then
    operation, payload = "withdraw", { name = args[2], count = tonumber(args[3]) or 1 }
elseif command == "put" or command == "deposit" then
    operation, payload = "deposit", { name = args[2], count = tonumber(args[3]) or 1 }
elseif command == "craft" then
    operation, payload = "craft", { name = args[2], count = tonumber(args[3]) or 1 }
else
    usage()
    return
end

local requestId = ("ctl:%d:%d"):format(os.getComputerID(), os.epoch("utc"))
rednet.send(serverId, {
    kind = "request", id = requestId, key = config.sharedKey,
    operation = operation, payload = payload
}, config.protocol)

local timeout = (operation == "withdraw" or operation == "craft") and 55 or 8
local deadline = os.epoch("utc") + timeout * 1000
local answer
while os.epoch("utc") < deadline do
    local sender, message = rednet.receive(config.protocol, 0.5)
    if sender == serverId and type(message) == "table"
            and message.kind == "response" and message.id == requestId then
        answer = message
        break
    end
end
if not wasOpen then rednet.close(modemName) end
if not answer then error("request timeout", 0) end
if not answer.ok then error(answer.error or "request failed", 0) end

if operation == "stock" then
    local items = answer.data and answer.data.items or {}
    print(("%-42s %s"):format("ITEM", "COUNT"))
    for _, item in ipairs(items) do
        print(("%-42s %d%s"):format(item.name, item.count or 0,
            item.craftable and " [craft]" or ""))
    end
    print("Items: " .. #items)
else
    print(textutils.serialize(answer.data))
end
