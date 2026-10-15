local api = require("m2os.api")

local app = {
    id = "desktop",
    name = "M2 Desktop",
    menuLabel = "HUD FRAME",
    menuOrder = 10,
    priority = 10,
    defaultEnabled = true
}

local objects = {}
local logoData

local MARGIN = 10
local LOGO_W, LOGO_H = 87, 35
local PANEL_W, PANEL_H = 135, 47
local FRAME_INSET, FRAME_CUT, FRAME_GAP = 5, 11, 31

local function loadLogo(options)
    local path = options.logoFile
    if fs.exists(path) and not fs.isDir(path) then
        local handle = fs.open(path, "rb")
        if handle then
            local data = handle.readAll()
            handle.close()
            if data and #data > 0 then return data end
        end
    end

    -- Download only when the cache is absent. Every later boot reads the file.
    if not http or not http.get or not options.logoUrl then return nil end
    local ok, response = pcall(http.get, options.logoUrl, nil, true)
    if not ok or not response then return nil end
    local data = response.readAll()
    response.close()
    if not data or #data == 0 then return nil end
    local handle = fs.open(path, "wb")
    if handle then
        handle.write(data)
        handle.close()
    end
    return data
end

local function frameLine(ctx, x1, y1, x2, y2, color)
    ctx.ui.line(x1, y1, x2, y2, color, 0.12, 4, 19)
    ctx.ui.line(x1, y1, x2, y2, color, 0.78, 1.15, 20)
end

local function drawFrame(ctx, width, height)
    local theme = ctx.config.theme
    local i, c, g = FRAME_INSET, FRAME_CUT, FRAME_GAP
    local center = width / 2

    frameLine(ctx, i, i + c, i + c, i, theme.blue)
    frameLine(ctx, i + c, i, center - g, i, theme.blue)
    frameLine(ctx, center + g, i, width - i - c, i, theme.blue)
    frameLine(ctx, width - i - c, i, width - i, i + c, theme.purple)
    frameLine(ctx, i, i + c, i, height * 0.36, theme.blue)
    frameLine(ctx, i, height * 0.64, i, height - i - c, theme.purple)
    frameLine(ctx, width - i, i + c, width - i, height * 0.36, theme.purple)
    frameLine(ctx, width - i, height * 0.64, width - i, height - i - c, theme.blue)
    frameLine(ctx, i, height - i - c, i + c, height - i, theme.purple)
    frameLine(ctx, i + c, height - i, center - g, height - i, theme.purple)
    frameLine(ctx, center + g, height - i, width - i - c, height - i, theme.blue)
    frameLine(ctx, width - i - c, height - i, width - i, height - i - c, theme.blue)
    frameLine(ctx, center - 20, i + 2, center - 5, i + 2, theme.purple)
    frameLine(ctx, center + 5, i + 2, center + 20, i + 2, theme.blue)
    frameLine(ctx, center - 16, height - i - 2, center - 4, height - i - 2, theme.blue)
    frameLine(ctx, center + 4, height - i - 2, center + 16, height - i - 2, theme.purple)
    ctx.ui.rectangle(i + c + 3, i + 3, 14, 1.5, theme.purple, 0.9, 21)
    ctx.ui.rectangle(width - i - c - 17, i + 3, 14, 1.5, theme.blue, 0.9, 21)
end

local function draw(ctx)
    ctx.ui.clear()
    objects = {}
    local width, height = ctx.system.getSize()
    local theme = ctx.config.theme
    drawFrame(ctx, width, height)

    local leftX = MARGIN
    local panelY = height - PANEL_H - MARGIN

    -- The panel is a texture, not a rectangle. AP renders it before the PNG,
    -- so the translucent background cannot tint the logo.
    ctx.ui.textureRect(leftX, panelY, PANEL_W, PANEL_H, theme.background, 0.60, 0)
    ctx.ui.rectangle(leftX, panelY, 3, PANEL_H, theme.purple, 1, 2)

    if logoData then
        local logo = ctx.ui.raw("Texture", {
            gui = true, x = leftX + 8, y = panelY + 4, z = 100,
            sizeX = LOGO_W, sizeY = LOGO_H, color = theme.white, opacity = 1,
            depthTest = false, depthMask = false
        })
        local ok = pcall(function()
            logo.load(logoData)
            logo.setSizes(LOGO_W, LOGO_H)
        end)
        if not ok then
            ctx.ui.text(leftX + 10, panelY + 20, "LOGO ERROR", theme.purple, 0.9, 110)
        end
    else
        ctx.ui.text(leftX + 10, panelY + 20, "NO LOGO CACHE", theme.purple, 0.9, 110)
    end
    ctx.ui.text(leftX + 8, panelY + 38, "M2OS ONLINE", theme.gray, 0.85, 110)

    local rightX = width - PANEL_W - MARGIN
    ctx.ui.rectangle(rightX, panelY, PANEL_W, PANEL_H, theme.background, 0.60, 0)
    ctx.ui.rectangle(rightX, panelY, PANEL_W / 2, 2, theme.purple, 1, 1)
    ctx.ui.rectangle(rightX + PANEL_W / 2, panelY, PANEL_W / 2, 2, theme.blue, 1, 1)
    ctx.ui.text(rightX + 8, panelY + 7, "POSITION DATA", theme.blue, 0.95, 10)
    objects.position = ctx.ui.text(rightX + 8, panelY + 20, "X:--- Y:--- Z:---", theme.white, 0.85, 10)
    objects.time = ctx.ui.text(rightX + 8, panelY + 33, "TIME --:--", theme.gray, 0.85, 10)
end

function app.start(ctx)
    logoData = logoData or loadLogo(ctx.config.desktop)
    draw(ctx)
end

function app.resize(ctx)
    draw(ctx)
end

function app.update(ctx)
    local x, y, z = ctx.system.getEyePosition()
    if x and y and z and objects.position then
        objects.position.setContent(("X:%d Y:%d Z:%d"):format(
            math.floor(x), math.floor(y - 1.62), math.floor(z)))
    end
    if objects.time then
        local time = os.time("ingame")
        objects.time.setContent(("TIME %02d:%02d"):format(
            math.floor(time) % 24, math.floor((time % 1) * 60)))
    end
end

function app.stop()
    objects = {}
end

api.registerApp(app)
return app
