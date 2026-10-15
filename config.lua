return {
    name = "M2OS",
    version = "0.1.0",
    stateFile = "/m2os-state.cfg",

    theme = {
        purple = 0xA347F5,
        blue = 0x399BFF,
        white = 0xFFFFFF,
        gray = 0xB8C2D0,
        background = 0x101020,
        red = 0xFF3038,
        green = 0x43E38C,
        amber = 0xFFB84A
    },

    desktop = {
        logoFile = "/m2-corp-logo.png",
        logoUrl = "http://80.68.2.81:53456/m2-corp-logo-transperent.png"
    },

    tracker = {
        range = 16,
        intervalMs = 2100,
        maxTargets = 5,
        aggressiveOnly = true,
        boxThickness = 0.045
    },

    context = {
        visibleSeconds = 5,
        dimension = "minecraft:overworld"
    },

    storage = {
        protocol = "m2os.storage.v1",
        sharedKey = "m2os",
        serverId = nil,
        maxRows = 8,
        gridColumns = 8,
        gridRows = 4
    },

    modules = {
        "m2os.apps.desktop",
        "m2os.apps.storage",
        "m2os.apps.context",
        "m2os.apps.mob_tracker",
        "m2os.apps.radial_menu"
    }
}
