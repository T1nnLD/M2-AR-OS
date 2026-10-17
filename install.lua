-- M2OS installer for CC:Tweaked
-- Usage: wget run <raw-url>/install.lua [glasses|server|all]

local REPOSITORY = "https://raw.githubusercontent.com/T1nnLD/M2-AR-OS/master/"
local INSTALLER_VERSION = "2.3-no-autostart"
local args = { ... }

local cacheBuster = tostring(os.clock())
if os.epoch then
    local ok, value = pcall(os.epoch, "utc")
    if ok and value then cacheBuster = tostring(value) end
end

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

-- Recover an interrupted older update and remove its orphaned copies before
-- downloading anything. This is important on the default 1 MB CC disk.
for _, entry in ipairs(files) do
    local target = entry[2]
    local temp, backup = target .. ".m2tmp", target .. ".bak"
    if fs.exists(temp) then fs.delete(temp) end
    if fs.exists(backup) then
        if fs.exists(target) then
            fs.delete(backup)
        else
            ensureParent(target)
            fs.move(backup, target)
        end
    end
end

local function download(remotePath)
    -- raw.githubusercontent.com may cache the previous master revision for a
    -- few minutes. A unique query per install guarantees that every project
    -- file belongs to the version the user has just requested.
    local url = REPOSITORY .. remotePath .. "?m2os=" .. cacheBuster
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

writeLine(("Installing M2OS (%s, %s)..."):format(
    mode, INSTALLER_VERSION), COLORS.lightBlue)

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
            error(("Cannot download %s: %s"):format(remotePath, tostring(reason)), 0)
        end
        local temp = target .. ".m2tmp"
        ensureParent(temp)
        if fs.exists(temp) then fs.delete(temp) end
        local keepBackup = fs.exists(target)
        local free = fs.getFreeSpace and fs.getFreeSpace("/") or "unlimited"
        if keepBackup and type(free) == "number" and free < #data then
            -- The downloaded response is already safely in memory. On a full
            -- disk, remove the old copy now so the smaller replacement can be
            -- written without needing room for both versions at once.
            if free + fs.getSize(target) < #data then
                error(("Not enough disk space for %s (need %d bytes)"):format(
                    target, #data), 0)
            end
            fs.delete(target)
            keepBackup = false
        end
        local handle = fs.open(temp, "wb")
        if not handle then error("Cannot write " .. temp, 0) end
        local wrote, writeError = pcall(handle.write, data)
        handle.close()
        if not wrote then
            if fs.exists(temp) then fs.delete(temp) end
            color(COLORS.red)
            print("FAILED")
            color(COLORS.white)
            error(("Cannot write %s: %s"):format(temp,
                tostring(writeError or "out of space")), 0)
        end

        -- Replace one file at a time and delete its backup immediately. The
        -- previous installer staged the entire project and kept every .bak,
        -- temporarily using two or three times the required disk space.
        local backup = target .. ".bak"
        ensureParent(target)
        if fs.exists(backup) then fs.delete(backup) end
        if keepBackup and fs.exists(target) then fs.move(target, backup) end
        local ok, reason = pcall(fs.move, temp, target)
        if not ok then
            if fs.exists(backup) and not fs.exists(target) then
                fs.move(backup, target)
            end
            if fs.exists(temp) then fs.delete(temp) end
            error("Cannot install " .. target .. ": " .. tostring(reason), 0)
        end
        if fs.exists(backup) then fs.delete(backup) end
        writeLine("OK", COLORS.lime)
    end
end

-- Version 2.2 briefly installed its own startup helper. Startup policy belongs
-- to the computer owner, so remove only that exact obsolete file. A user's
-- root /startup.lua is never touched.
if (mode == "server" or mode == "all")
        and fs.exists("/startup/m2os_server.lua")
        and not fs.isDir("/startup/m2os_server.lua") then
    fs.delete("/startup/m2os_server.lua")
    writeLine("Removed obsolete /startup/m2os_server.lua", COLORS.orange)
end

-- A successful update must never leave installer-owned copies behind.
for _, entry in ipairs(files) do
    local target = entry[2]
    local temp, backup = target .. ".m2tmp", target .. ".bak"
    if fs.exists(temp) then fs.delete(temp) end
    if fs.exists(backup) then fs.delete(backup) end
end

writeLine("", COLORS.white)
writeLine("M2OS installed successfully.", COLORS.lime)
if mode == "glasses" or mode == "all" then print("Start HUD:  m2os") end
if mode == "server" or mode == "all" then
    print("Edit:       edit m2os/server_config.lua")
    print("Start:      m2os_server")
end
print("Update by running the same wget command again.")
