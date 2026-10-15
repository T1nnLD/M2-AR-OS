local args = { ... }

if args[1] == "help" or args[1] == "--help" then
    print("M2OS HUD")
    print("  m2os        start the glasses OS")
    print("  m2ctl help  storage command line client")
    print("  m2os_server start the Create storage bridge")
    return
end

local Kernel = require("m2os.kernel")
local config = require("m2os.config")

Kernel.run(config)
