-- M2OS installer for CC:Tweaked
-- Usage: wget run <raw-url>/install.lua [glasses|server|all]

local REPOSITORY = "https://raw.githubusercontent.com/T1nnLD/M2-AR-OS/master/"
local args = { ... }

local COLORS = colors or {
    white = 1, orange = 2, lime = 32, red = 16384,
    lightBlue = 8, gray = 128
}

local function color(value)
    if term.isColor and term.isColor() then term.setTextColor(value) end
end

local function writeLine(message, value)
    color(value or COLORS.white)
    print(message)
    color(COLORS.white)
end

local mode = args[1] and args[1]:lower() or nil
if mode == "client" or mode == "hud" then mode = "glasses" end

if not mode then
    writeLine("M2OS INSTALLER", COLORS.lightBlue)
    print("1. Smart Glasses / client")
    print("2. Create storage server")
    print("3. Both")
    write("Select [1]: ")
    local answer = read()
    if answer == "2" then mode = "server"
    elseif answer == "3" then mode = "all"
    else mode = "glasses" end
end

if mode ~= "glasses" and mode ~= "server" and mode ~= "all" then
    error("mode must be glasses, server or all", 0)
end

if not http or not http.get then
    error("HTTP API is disabled in ComputerCraft configuration", 0)
end

local common = {
    { "lib/util.lua", "/m2os/lib/util.lua" },
    { "lib/i18n.lua", "/m2os/lib/i18n.lua" },
    { "lang/ru_ru.lua", "/m2os/lang/ru_ru.lua" },
    { "README.md", "/m2os/README.md" },
    { "API.md", "/m2os/API.md" }
}

local glasses = {
    { "api.lua", "/m2os/api.lua" },
    { "config.lua", "/m2os/config.lua", preserve = true },
    { "kernel.lua", "/m2os/kernel.lua" },
    { "apps/desktop.lua", "/m2os/apps/desktop.lua" },
    { "apps/storage.lua", "/m2os/apps/storage.lua" },
    { "apps/context.lua", "/m2os/apps/context.lua" },
    { "apps/mob_tracker.lua", "/m2os/apps/mob_tracker.lua" },
    { "apps/radial_menu.lua", "/m2os/apps/radial_menu.lua" },
    { "bin/m2os.lua", "/m2os.lua" },
    { "bin/m2ctl.lua", "/m2ctl.lua" }
}

local server = {
    { "server.lua", "/m2os/server.lua" },
    { "server_config.lua", "/m2os/server_config.lua", preserve = true },
    { "bin/m2os_server.lua", "/m2os_server.lua" }
}

local files, known = {}, {}
local function include(entries)
    for _, entry in ipairs(entries) do
        if not known[entry[2]] then
            known[entry[2]] = true
            files[#files + 1] = entry
        end
    end
end

include(common)
if mode == "glasses" or mode == "all" then include(glasses) end
if mode == "server" or mode == "all" then include(server) end

local function ensureParent(path)
    local parent = fs.getDir(path)
    if parent ~= "" and not fs.exists(parent) then fs.makeDir(parent) end
end

local function download(remotePath)
    local url = REPOSITORY .. remotePath
    local response, reason = http.get(url, {
        ["User-Agent"] = "M2OS-Installer/1.0"
    }, true)
    if not response then return nil, reason or "HTTP request failed" end
    local code = response.getResponseCode and response.getResponseCode() or 200
    local data = response.readAll()
    response.close()
    if code < 200 or code >= 300 then
        return nil, "HTTP " .. tostring(code)
    end
    if not data or #data == 0 then return nil, "empty response" end
    return data
end

local staged = {}
writeLine(("Installing M2OS (%s)..."):format(mode), COLORS.lightBlue)

for index, entry in ipairs(files) do
    local remotePath, target = entry[1], entry[2]
    if entry.preserve and fs.exists(target) then
        writeLine(("[%d/%d] keep %s"):format(index, #files, target), COLORS.orange)
    else
        write(("[%d/%d] %s ... "):format(index, #files, remotePath))
        local data, reason = download(remotePath)
        if not data then
            color(COLORS.red)
            print("FAILED")
            color(COLORS.white)
            for _, item in ipairs(staged) do
                if fs.exists(item.temp) then fs.delete(item.temp) end
            end
            error(("Cannot download %s: %s"):format(remotePath, tostring(reason)), 0)
        end
        local temp = target .. ".m2tmp"
        ensureParent(temp)
        if fs.exists(temp) then fs.delete(temp) end
        local handle = fs.open(temp, "wb")
        if not handle then error("Cannot write " .. temp, 0) end
        handle.write(data)
        handle.close()
        staged[#staged + 1] = { temp = temp, target = target }
        writeLine("OK", COLORS.lime)
    end
end

for _, item in ipairs(staged) do
    local backup = item.target .. ".bak"
    ensureParent(item.target)
    if fs.exists(backup) then fs.delete(backup) end
    if fs.exists(item.target) then fs.move(item.target, backup) end
    local ok, reason = pcall(fs.move, item.temp, item.target)
    if not ok then
        if fs.exists(backup) and not fs.exists(item.target) then fs.move(backup, item.target) end
        error("Cannot install " .. item.target .. ": " .. tostring(reason), 0)
    end
end

writeLine("", COLORS.white)
writeLine("M2OS installed successfully.", COLORS.lime)
if mode == "glasses" or mode == "all" then print("Start HUD:  m2os") end
if mode == "server" or mode == "all" then
    print("Edit:       edit m2os/server_config.lua")
    print("Start:      m2os_server")
end
print("Update by running the same wget command again.")
