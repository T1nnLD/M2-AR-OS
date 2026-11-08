local util=require("m2os.lib.util")
local Binding={}
Binding.__index=Binding
local ROWS=6

function Binding.new(ctx,onBound,onClose)
    return setmetatable({ctx=ctx,onBound=onBound,onClose=onClose,open=false},Binding)
end

function Binding:draw()
    if not self.open then return end
    local ctx=self.ctx
    ctx.ui.clear()
    local width,height=ctx.system.getSize()
    local scale=math.max(0.1,math.min(1,(width-12)/360,(height-12)/252))
    local left,top=(width-360*scale)/2,(height-252*scale)/2
    local theme=ctx.config.theme
    self.geometry={left=left,top=top,scale=scale}
    local function text(x,y,value,color,size)
        ctx.ui.text(left+x*scale,top+y*scale,value,color or theme.white,(size or 0.78)*scale,76,false)
    end
    ctx.ui.textureRect(left,top,360*scale,252*scale,theme.background,1,70)
    ctx.ui.rectangle(left,top,360*scale,2*scale,theme.purple,1,72)
    text(12,10,"ПРИВЯЗКА БЛОКА",theme.white,1)
    text(12,29,util.short(self.target.name or "Блок",50),theme.gray)
    text(12,43,("%d / %d / %d"):format(self.target.x,self.target.y,self.target.z),theme.gray)
    local page=math.floor((self.selected-1)/ROWS)
    self.visible={}
    for row=1,ROWS do
        local index=page*ROWS+row
        local item=self.items[index]
        if item then
            local y=62+(row-1)*24
            ctx.ui.rectangle(left+10*scale,top+y*scale,340*scale,22*scale,
                index==self.selected and theme.purple or 0x293044,1,73)
            text(15,y+4,util.short((item.current and "* " or "")..item.name,49))
            self.visible[#self.visible+1]={index=index,x=left+10*scale,y=top+y*scale,w=340*scale,h=22*scale}
        end
    end
    text(12,210,util.short(self.message,55),self.bad and theme.red or self.done and theme.green or theme.gray,0.72)
    text(12,228,"Колесо / ↑↓: выбор · ЛКМ / Enter: сохранить · Esc",theme.gray,0.68)
    self.pointerX=util.clamp(self.pointerX or width/2,left,left+360*scale)
    self.pointerY=util.clamp(self.pointerY or height/2,top,top+252*scale)
    self.cursor=util.createTopCursor(ctx.ui,self.pointerX,self.pointerY,90,theme)
end

function Binding:show(target)
    if self.open then return end
    local mode=self.ctx.system.getInputMode()
    if mode and mode~="context" then self.ctx.notify("Сначала закрой текущее окно") return end
    local storage=self.ctx.services.get("storage")
    if not storage or type(storage.request)~="function" then self.ctx.notify("Нужен запущенный модуль склада") return end
    self.open=true
    self.target=util.copy(target)
    self.items,self.selected={},1
    self.pointerX,self.pointerY=nil,nil
    self.message,self.bad,self.done,self.pending="Поиск подключённых устройств…",false,false,true
    self.ctx.system.setInputMode("context")
    self:draw()
    self.ctx.system.flushOverlay()
    local session={}
    self.session=session
    storage.request("context_discover",self.target,function(ok,data,err)
        if not self.open or self.session~=session then return end
        self.pending=false
        self.items=ok and type(data)=="table" and data.providers or {}
        if type(self.items)~="table" then self.items={} end
        self.bad=not ok
        self.message=not ok and tostring(err or "Ошибка поиска; обнови мост")
            or (#self.items>0 and "Выбери устройство именно этого блока / его Reader"
                or "Нет устройств. Подключи блок к проводной сети моста.")
        self:draw()
    end)
end

function Binding:close()
    if not self.open then return end
    self.open=false
    self.session=nil
    if self.ctx.system.getInputMode()=="context" then self.ctx.system.setInputMode(nil) end
    self.ctx.ui.clear()
    if self.onClose then self.onClose() end
end

function Binding:confirm()
    if self.pending or self.done then return end
    local item=self.items[self.selected]
    if not item then return end
    local storage=self.ctx.services.get("storage")
    if not storage or type(storage.request)~="function" then return end
    local payload=util.copy(self.target)
    payload.provider=item.name
    self.pending,self.message,self.bad=true,"Сохранение привязки…",false
    self:draw()
    local session=self.session
    storage.request("context_bind",payload,function(ok,data,err)
        if not self.open or self.session~=session then return end
        self.pending=false
        self.bad,self.done=not ok,ok
        self.message=ok and "Привязка сохранена. Esc — вернуться в игру"
            or tostring(err or "Не удалось сохранить привязку")
        if ok and self.onBound then self.onBound(self.target,data) end
        self:draw()
    end)
end

local function numbers(...)
    local values={}
    for _,value in ipairs({...}) do if type(value)=="number" then values[#values+1]=value end end
    return values
end

function Binding:onEvent(event,...)
    if not self.open then return end
    local values=numbers(...)
    if event=="keyboard_close" then self:close() return true end
    if event=="key" then
        if values[1]==keys.escape then self:close()
        elseif not self.pending and not self.done then
            local held=false
            for _,value in ipairs({...}) do if value==true then held=true end end
            if values[1]==keys.up then self.selected=math.max(1,self.selected-1) self:draw()
            elseif values[1]==keys.down then self.selected=math.min(math.max(1,#self.items),self.selected+1) self:draw()
            elseif values[1]==keys.enter and not held then self:confirm() end
        end
        return true
    elseif event=="player_mouse_scroll" then
        if not self.pending and not self.done and #self.items>0 then
            local direction=(values[1] or 0)>0 and 1 or -1
            self.selected=util.clamp(self.selected+direction,1,#self.items)
            self:draw()
        end
        return true
    elseif event=="player_mouse_move" and self.geometry then
        local g=self.geometry
        self.pointerX=util.clamp(self.pointerX+(values[#values-1] or 0),g.left,g.left+360*g.scale)
        self.pointerY=util.clamp(self.pointerY+(values[#values] or 0),g.top,g.top+252*g.scale)
        util.moveTopCursor(self.cursor,self.pointerX,self.pointerY,90)
        local now=util.epoch()
        if now>=(self.flushAt or 0) then self.flushAt=now+25 self.ctx.system.flushOverlay() end
        return true
    elseif event=="player_mouse_click" then
        if values[1]==0 or values[1]==1 then
            for _,row in ipairs(self.visible or {}) do
                if self.pointerX>=row.x and self.pointerX<row.x+row.w
                        and self.pointerY>=row.y and self.pointerY<row.y+row.h then
                    self.selected=row.index
                    self:confirm()
                    break
                end
            end
        end
        return true
    elseif event=="char" or event=="key_up" or event=="player_interaction" then return true end
end

return Binding
