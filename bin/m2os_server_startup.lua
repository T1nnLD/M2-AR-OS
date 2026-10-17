-- Keep the storage bridge available after a cold computer/server restart.
-- Advanced computers launch it in a background tab so other startup files can
-- still run. Normal computers fall back to the foreground.
if not fs.exists("/m2os_server.lua") then return end

if shell and type(shell.openTab) == "function" then
    local id = shell.openTab("/m2os_server.lua")
    if id and multishell and type(multishell.setTitle) == "function" then
        multishell.setTitle(id, "M2OS Bridge")
    end
else
    shell.run("/m2os_server.lua")
end
