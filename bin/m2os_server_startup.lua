-- Keep the storage bridge available after a cold computer/server restart.
-- Advanced computers launch it in a background tab so other startup files can
-- still run. Normal computers fall back to the foreground.
if not fs.exists("/m2os_server.lua") then return end

-- Keep an existing, user-owned startup.lua authoritative. On a normal
-- computer `shell.run("m2os_server")` blocks until the bridge exits; without
-- this guard CraftOS would then continue into startup/ and immediately start
-- a second copy, making Ctrl+T appear not to work.
local function rootStartupRunsBridge()
    local path = "/startup.lua"
    if not fs.exists(path) or fs.isDir(path) then return false end
    local handle = fs.open(path, "r")
    if not handle then return false end
    local source = handle.readAll() or ""
    handle.close()
    return source:find("m2os_server", 1, true) ~= nil
end

if rootStartupRunsBridge() then return end

if shell and type(shell.openTab) == "function" then
    local id = shell.openTab("/m2os_server.lua")
    if id and multishell and type(multishell.setTitle) == "function" then
        multishell.setTitle(id, "M2OS Bridge")
    end
else
    shell.run("/m2os_server.lua")
end
