local api=require("m2os.api")
local util=require("m2os.lib.util")
local Search=require("m2os.lib.block_search")
local app={id="block_search",name="Поиск блоков",priority=25,userToggle=false,
    persistent=false,defaultEnabled=true}
local state={}
local render
local PANEL_SETTLE_MS=180
local MAX_SETTLE_MS=500

local function clearGui(ctx)
    for _,object in ipairs(state.gui or {}) do ctx.ui.remove(object) end
    state.gui={}
    state.widgets=nil state.hits=nil state.cursor=nil
end

local function close(ctx)
    state.open=false
    state.drawAt=nil state.resizeStartedAt=nil
    clearGui(ctx)
    if ctx.system.getInputMode()==app.id then ctx.system.setInputMode(nil) end
end

local function startSearch(ctx,query)
    local normalized,err=Search.normalize(query)
    if not normalized then state.message=err state.bad=true return false,err end
    if ctx.system.cancelSensor then ctx.system.cancelSensor() end
    local ok,result=state.search:start(normalized)
    if not ok then state.message=result state.bad=true return false,result end
    if ctx.system.restartSensor then ctx.system.restartSensor() end
    state.query=result state.message=nil state.bad=false
    if state.path then
        local written,saved,err=pcall(util.writeTable,state.path,{version=1,query=result})
        if not written or not saved then ctx.notify("Поиск запущен; настройки не сохранены: "..tostring(written and err or saved),ctx.config.theme.amber) end
    end
    return true,result
end

local function stopSearch(ctx)
    if ctx.system.cancelSensor then ctx.system.cancelSensor() end
    state.search:stop() state.message=nil state.bad=false
end

local function updateContents(ctx)
    local widgets=state.widgets
    if not widgets then return end
    local theme=ctx.config.theme
    local function set(key,object,method,value)
        if widgets[key]~=value then object[method](value) widgets[key]=value end
    end
    set("queryValue",widgets.query,"setContent",state.query~="" and util.utf8Sub(state.query,-51) or "minecraft:diamond_ore")
    set("queryColor",widgets.query,"setColor",state.query~="" and theme.white or theme.gray)
    set("statusValue",widgets.status,"setContent",util.short(state.message or state.search.message,53))
    set("statusColor",widgets.status,"setColor",(state.bad or state.search.bad) and theme.red or theme.white)
    local nearest=state.search.nearest
    local detail=nearest and ("Ближайший: %d / %d / %d · %.1f м"):format(
        nearest.blockX,nearest.blockY,nearest.blockZ,math.sqrt(nearest.distance))
        or "Сканер: в очках · подсветка видна сквозь блоки"
    set("detailValue",widgets.detail,"setContent",detail)
end

local function draw(ctx)
    local pointerX,pointerY
    if state.scale and state.px and state.py then
        pointerX=(state.px-state.x)/state.scale
        pointerY=(state.py-state.y)/state.scale
    end
    clearGui(ctx)
    if not state.open then return end
    -- GUI and world markers share an app owner but have separate lifetimes.
    local ui={}
    for _,method in ipairs({"text","rectangle","textureRect","raw"}) do
        local name=method
        ui[name]=function(...)
            local object=ctx.ui[name](...)
            state.gui[#state.gui+1]=object
            return object
        end
    end
    local width,height=ctx.system.getSize()
    local s=math.max(0.1,math.min(1,(width-12)/360,(height-12)/220))
    local x,y=(width-360*s)/2,(height-220*s)/2
    state.x,state.y,state.scale=x,y,s
    if pointerX then state.px=x+pointerX*s state.py=y+pointerY*s end
    local theme=ctx.config.theme
    local function text(px,py,value,color,size)
        return ui.text(x+px*s,y+py*s,value,color or theme.white,(size or 0.78)*s,76,false)
    end
    state.widgets={}
    state.hits={}
    local function button(px,py,w,h,label,run)
        ui.rectangle(x+px*s,y+py*s,w*s,h*s,0x293044,1,73)
        text(px+5,py+5,label)
        state.hits[#state.hits+1]={x=x+px*s,y=y+py*s,w=w*s,h=h*s,run=run}
    end
    ui.textureRect(x,y,360*s,220*s,theme.background,1,70)
    ui.rectangle(x,y,360*s,2*s,theme.purple,1,72)
    text(12,10,"ПОИСК БЛОКОВ",theme.white,1)
    text(12,30,"ID блока или #тег:",theme.gray)
    ui.rectangle(x+12*s,y+47*s,336*s,24*s,0x293044,1,73)
    state.widgets.query=text(18,54,"")
    text(12,78,"Примеры: create:item_vault · #c:ores/diamond",theme.gray,0.70)
    text(12,101,"Непрерывный поиск при движении",theme.gray)
    button(12,124,162,23,"Искать / обновить",function() startSearch(ctx,state.query) end)
    button(184,124,164,23,"Остановить",function() stopSearch(ctx) end)
    state.widgets.status=text(12,157,"",theme.white,0.74)
    state.widgets.detail=text(12,177,"",theme.gray,0.70)
    text(12,201,"Enter: искать · Delete: очистить · Esc: в игру",theme.gray,0.68)
    state.px=util.clamp(state.px or width/2,x,x+360*s)
    state.py=util.clamp(state.py or height/2,y,y+220*s)
    state.cursor=util.createTopCursor(ui,state.px,state.py,90,theme)
    updateContents(ctx)
end

render=function(ctx,flush)
    if not state.open then return end
    local ok,err=pcall(function()
        if state.widgets then updateContents(ctx)
        elseif not state.drawAt then draw(ctx) end
        if flush~=false then ctx.system.flushOverlay() end
    end)
    if not ok then close(ctx) ctx.notify("Поиск: ошибка интерфейса: "..tostring(err),ctx.config.theme.red) end
end

local function show(ctx)
    if state.open then return end
    local mode=ctx.system.getInputMode()
    if mode and mode~=app.id then ctx.notify("Сначала закрой текущее окно",ctx.config.theme.amber) return end
    local keyboard=ctx.system.getModule("keyboard")
    if not keyboard then ctx.notify("Для ввода нужен модуль Keyboard",ctx.config.theme.amber) return end
    if type(keyboard.setCaptureMouse)=="function" then pcall(keyboard.setCaptureMouse,true) end
    state.open=true state.px=nil state.py=nil
    state.resizeStartedAt=util.epoch()
    state.drawAt=state.resizeStartedAt+PANEL_SETTLE_MS
    ctx.system.setInputMode(app.id)
end

function app.start(ctx)
    local options=ctx.config.blockSearch or {}
    local path=options.stateFile
    if path==nil then path="/m2os/block_search.cfg" end
    local ok,saved=true,{}
    if path then ok,saved=pcall(util.readTable,path,{}) end
    saved=ok and type(saved)=="table" and saved.version==1 and saved or {}
    local query=type(saved.query)=="string" and saved.query or ""
    state={open=false,gui={},query=query,path=path,
        search=Search.new(ctx)}
    ctx.menu.add({id="block_search.panel",label="ПОИСК БЛОКОВ",order=50,run=function() show(ctx) end})
    ctx.services.provide("block_search",{
        show=function() show(ctx) end,hide=function() close(ctx) end,
        start=function(query)
            local success,result=startSearch(ctx,query)
            render(ctx) return success,result
        end,
        stop=function() stopSearch(ctx) render(ctx) end,
        status=function()
            return {active=state.search.active,query=state.search.query,radius=state.search.radius,
                actualRadius=state.search.scanRange,intervalMs=state.search.interval,total=state.search.total,shown=state.search.shown,
                message=state.search.message,nearest=util.copy(state.search.nearest)}
        end
    })
end

function app.onEvent(ctx,event,...)
    local values={}
    for _,value in ipairs({...}) do if type(value)=="number" then values[#values+1]=value end end
    if event=="peripheral_detach" and ({...})[1]==state.search.scannerName then
        if ctx.system.cancelSensor then ctx.system.cancelSensor() end
        state.search.scanner=nil state.search:clear()
        if state.search.active and ctx.system.restartSensor then ctx.system.restartSensor() end
    end
    if not state.open then return end
    if event=="keyboard_close" then close(ctx) return true end
    if event=="key" then
        local code=values[1]
        local held=false
        for _,value in ipairs({...}) do if value==true then held=true end end
        if code==keys.escape then close(ctx)
        elseif code==keys.enter and not held then startSearch(ctx,state.query) render(ctx)
        elseif code==keys.backspace then state.query=util.utf8Backspace(state.query) state.message=nil render(ctx)
        elseif code==keys.delete then state.query="" state.message=nil render(ctx) end
        return true
    elseif event=="char" or event=="paste" then
        local input=({...})[1]
        if type(input)=="string" then
            state.query=state.query..util.utf8Sub(input,1,math.max(0,128-util.utf8Length(state.query)))
            state.message=nil render(ctx)
        end
        return true
    elseif event=="player_mouse_move" then
        if not state.widgets then return true end
        state.px=util.clamp(state.px+(values[#values-1] or 0),state.x,state.x+360*state.scale)
        state.py=util.clamp(state.py+(values[#values] or 0),state.y,state.y+220*state.scale)
        util.moveTopCursor(state.cursor,state.px,state.py,90)
        local now=util.epoch()
        if now>=(state.flushAt or 0) then state.flushAt=now+25 ctx.system.flushOverlay() end
        return true
    elseif event=="player_mouse_click" then
        if values[1]==0 or values[1]==1 then
            for _,hit in ipairs(state.hits or {}) do
                if state.px>=hit.x and state.px<hit.x+hit.w and state.py>=hit.y and state.py<hit.y+hit.h then hit.run() render(ctx) break end
            end
        end
        return true
    elseif event=="key_up" or event=="player_interaction" or event=="player_mouse_scroll" then return true end
end

function app.update(ctx,now)
    if state.open and not state.widgets and state.drawAt and now<state.drawAt then return end
    if state.open and state.drawAt and now>=state.drawAt then
        state.drawAt=nil state.resizeStartedAt=nil
        -- Keep the old layout clickable until the settled replacement is
        -- ready, then replace it in one batch and publish before native scans.
        clearGui(ctx)
        render(ctx)
    end
    if state.open then render(ctx,false) end
end
function app.poll(ctx,now)
    if state.open and not state.widgets and state.drawAt and now<state.drawAt then return end
    state.search:update(now)
end
function app.resize(ctx)
    if not state.open then return end
    local now=util.epoch()
    state.resizeStartedAt=state.resizeStartedAt or now
    state.drawAt=math.min(now+PANEL_SETTLE_MS,state.resizeStartedAt+MAX_SETTLE_MS)
end
function app.stop(ctx) close(ctx) state.search:stop() end

api.registerApp(app)
return app
