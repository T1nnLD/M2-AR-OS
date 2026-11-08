local api=require("m2os.api")
local util=require("m2os.lib.util")
local Search=require("m2os.lib.block_search")
local app={id="block_search",name="Поиск блоков",priority=25,userToggle=false,
    persistent=false,defaultEnabled=true}
local state={}
local render

local function clearGui(ctx)
    for _,object in ipairs(state.gui or {}) do ctx.ui.remove(object) end
    state.gui={}
end

local function close(ctx)
    state.open=false
    clearGui(ctx)
    if ctx.system.getInputMode()==app.id then ctx.system.setInputMode(nil) end
end

local function startSearch(ctx,query,radius)
    local ok,result=state.search:start(query,radius)
    if not ok then state.message=result state.bad=true return false,result end
    state.query=result state.radius=state.search.radius state.message=nil state.bad=false
    if state.path then
        local written,saved,err=pcall(util.writeTable,state.path,{version=1,query=result,radius=state.radius})
        if not written or not saved then ctx.notify("Поиск запущен; настройки не сохранены: "..tostring(written and err or saved),ctx.config.theme.amber) end
    end
    return true,result
end

local function draw(ctx)
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
    local theme=ctx.config.theme
    local function text(px,py,value,color,size)
        ui.text(x+px*s,y+py*s,value,color or theme.white,(size or 0.78)*s,76,false)
    end
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
    text(18,54,state.query~="" and util.utf8Sub(state.query,-51) or "minecraft:diamond_ore",state.query~="" and theme.white or theme.gray)
    text(12,78,"Примеры: create:item_vault · #c:ores/diamond",theme.gray,0.70)
    local actual=state.search.scanRange
    text(12,101,"Радиус: "..state.radius..(actual and (" · фактически: "..actual) or ""),theme.gray)
    button(264,94,38,21,"-",function() state.radius=math.max(1,state.radius-1) end)
    button(309,94,39,21,"+",function() state.radius=math.min(16,state.radius+1) end)
    button(12,124,162,23,"Искать / обновить",function() startSearch(ctx,state.query,state.radius) end)
    button(184,124,164,23,"Остановить",function() state.search:stop() state.message=nil state.bad=false end)
    text(12,157,util.short(state.message or state.search.message,53),
        (state.bad or state.search.bad) and theme.red or theme.white,0.74)
    local nearest=state.search.nearest
    local detail=nearest and ("Ближайший: %d / %d / %d · %.1f м"):format(
        nearest.blockX,nearest.blockY,nearest.blockZ,math.sqrt(nearest.distance))
        or "Сканер: в очках · подсветка видна сквозь блоки"
    text(12,177,detail,theme.gray,0.70)
    text(12,201,"Enter: искать · Delete: очистить · Esc: в игру",theme.gray,0.68)
    state.px=util.clamp(state.px or width/2,x,x+360*s)
    state.py=util.clamp(state.py or height/2,y,y+220*s)
    state.cursor=util.createTopCursor(ui,state.px,state.py,90,theme)
end

render=function(ctx)
    if not state.open then return end
    local ok,err=pcall(function() draw(ctx) ctx.system.flushOverlay() end)
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
    ctx.system.setInputMode(app.id)
    render(ctx)
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
        radius=math.max(1,math.min(16,math.floor(tonumber(saved.radius or options.range) or 8))),
        search=Search.new(ctx)}
    ctx.menu.add({id="block_search.panel",label="ПОИСК БЛОКОВ",order=50,run=function() show(ctx) end})
    ctx.services.provide("block_search",{
        show=function() show(ctx) end,hide=function() close(ctx) end,
        start=function(query,radius)
            local success,result=startSearch(ctx,query,radius or state.radius)
            render(ctx) return success,result
        end,
        stop=function() state.search:stop() state.message=nil state.bad=false render(ctx) end,
        status=function()
            return {active=state.search.active,query=state.search.query,radius=state.radius,
                actualRadius=state.search.scanRange,total=state.search.total,shown=state.search.shown,
                message=state.search.message,nearest=util.copy(state.search.nearest)}
        end
    })
end

function app.onEvent(ctx,event,...)
    local values={}
    for _,value in ipairs({...}) do if type(value)=="number" then values[#values+1]=value end end
    if event=="peripheral_detach" and ({...})[1]==state.search.scannerName then
        state.search.scanner=nil state.search:clear()
    end
    if not state.open then return end
    if event=="keyboard_close" then close(ctx) return true end
    if event=="key" then
        local code=values[1]
        local held=false
        for _,value in ipairs({...}) do if value==true then held=true end end
        if code==keys.escape then close(ctx)
        elseif code==keys.enter and not held then startSearch(ctx,state.query,state.radius) render(ctx)
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
    elseif event=="player_mouse_move" and state.scale then
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
    local function signature()
        return (state.search.message or "")..":"..tostring(state.search.shown)..":"
            ..tostring(state.search.nearest and state.search.nearest.key)..":"..tostring(state.search.scanRange)
    end
    local old=signature()
    state.search:update(now)
    local current=signature()
    if state.open and old~=current then render(ctx) end
end
function app.resize(ctx) render(ctx) end
function app.stop(ctx) close(ctx) state.search:stop() end

api.registerApp(app)
return app
