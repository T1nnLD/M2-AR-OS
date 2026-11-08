local util=require("m2os.lib.util")
local Panel={}
Panel.__index=Panel
local ROWS=5
function Panel.new(ctx,request)
    return setmetatable({ctx=ctx,request=request,open=false},Panel)
end
function Panel:draw()
    if not self.open then return end
    local ctx=self.ctx
    ctx.ui.clear()
    local width,height=ctx.system.getSize()
    local s=math.max(0.1,math.min(1,(width-12)/360,(height-12)/294))
    local x,y=(width-360*s)/2,(height-294*s)/2
    local theme=ctx.config.theme
    local function text(px,py,value,color,size)
        ctx.ui.text(x+px*s,y+py*s,value,color or theme.white,(size or 0.76)*s,76,false)
    end
    self.hits={}
    local function button(id,px,py,w,h,label,run,color)
        ctx.ui.rectangle(x+px*s,y+py*s,w*s,h*s,color or 0x293044,1,73)
        text(px+4,py+5,label)
        self.hits[#self.hits+1]={id=id,x=x+px*s,y=y+py*s,w=w*s,h=h*s,run=run}
    end
    ctx.ui.textureRect(x,y,360*s,294*s,theme.background,1,70)
    ctx.ui.rectangle(x,y,360*s,2*s,theme.purple,1,72)
    text(12,10,"АВТОПОПОЛНЕНИЕ",theme.white,1)
    text(12,28,"На складе: наведи на предмет и нажми K",theme.gray,0.72)
    local page=math.floor((self.selected-1)/ROWS)
    for row=1,ROWS do
        local index=page*ROWS+row
        local rule=self.rules[index]
        if rule then
            button("rule"..index,12,45+(row-1)*23,336,21,
                util.short((rule.enabled and "+ " or "- ")..rule.label,35).." ≥"..rule.count,
                function() self:select(index) self:draw() end,index==self.selected and theme.purple or nil)
        end
    end
    local rule=self.rules[self.selected]
    text(12,166,util.short(rule and rule.name or "Выбери предмет на складе клавишей K",53),theme.gray,0.70)
    text(12,180,"Считается общий остаток по ID, включая все варианты",theme.gray,0.66)
    text(12,201,"Держать минимум:")
    button("count",144,195,90,21,(self.focus and "> " or "")..self.count,
        function() self.focus=true self:draw() end,self.focus and theme.purple or nil)
    button("minus",240,195,47,21,"-",function() self:adjust(-1) end)
    button("plus",293,195,55,21,"+",function() self:adjust(1) end)
    button("save",12,224,108,21,"Сохранить",function() self:save() end)
    button("toggle",126,224,108,21,rule and rule.enabled and "Выключить" or "Включить",
        function() self:change(false) end)
    button("remove",240,224,108,21,"Удалить",function() self:change(true) end)
    local telemetry=rule and ((rule.current~=nil and ("Остаток: "..rule.current..". ") or "")..(rule.message or "")) or ""
    text(12,252,util.short(self.message or telemetry,53),self.bad and theme.red or theme.gray,0.72)
    text(12,274,"Enter: сохранить · Колесо/↑↓: правило · Esc: закрыть",theme.gray,0.66)
    self.x,self.y,self.scale=x,y,s
    self.px=util.clamp(self.px or width/2,x,x+360*s)
    self.py=util.clamp(self.py or height/2,y,y+294*s)
    self.cursor=util.createTopCursor(ctx.ui,self.px,self.py,90,theme)
end
function Panel:select(index)
    self.selected=index
    local rule=self.rules[index]
    self.count=tostring(rule and rule.count or 64)
    self.focus=false self.dirty=false self.message=nil self.bad=false
end
function Panel:apply(data,candidate)
    local prior=self.rules[self.selected]
    local selectedId=prior and prior.id
    self.rules=type(data)=="table" and type(data.rules)=="table" and data.rules or {}
    local index=1
    for i,rule in ipairs(self.rules) do
        if (candidate and rule.name==candidate.name) or (not candidate and prior
                and ((selectedId and rule.id==selectedId) or (not selectedId and rule.name==prior.name))) then index=i break end
    end
    local draft=candidate or self.candidate
    if draft then
        local found=false
        for _,rule in ipairs(self.rules) do if rule.name==draft.name then found=true end end
        if not found then
            self.rules[#self.rules+1]={name=draft.name,label=draft.displayName or draft.name,count=64,enabled=true}
            if candidate or (prior and prior.name==draft.name) then index=#self.rules end
        end
    end
    local count,dirty,focus=self.count,self.dirty,self.focus
    self:select(index)
    local current=self.rules[index]
    if prior and current and prior.name==current.name and prior.id==current.id then
        self.focus=focus
        if dirty then self.count=count self.dirty=dirty end
    end
end
function Panel:refresh(candidate)
    local session=self.session
    local revision=self.revision
    self.pollAt=util.epoch()+2000
    self.pollPending=true
    self.request("restock_status",{},function(ok,data,err)
        if not self.open or self.session~=session then return end
        self.pollPending=false
        if self.pending or revision~=self.revision then return end
        if ok then self:apply(data,candidate)
        else self.message=tostring(err or "Обнови мост хранилища") self.bad=true end
        self:draw()
    end)
end
function Panel:show(item)
    self.open=true self.session={}
    self.revision=0
    self.rules={} self.selected=1 self.count="64" self.focus=false self.dirty=false
    self.pending=false self.candidate=item and util.copy(item) or nil
    self.px,self.py=nil,nil
    self.message="Чтение правил…" self.bad=false
    self.ctrl,self.shift=false,false
    self.ctx.system.setInputMode("restock")
    self:draw()
    self.ctx.system.flushOverlay()
    self:refresh(self.candidate)
end
function Panel:close()
    self.open=false self.session=nil
    if self.ctx.system.getInputMode()=="restock" then self.ctx.system.setInputMode(nil) end
    self.ctx.ui.clear()
end
function Panel:adjust(direction)
    local step=self.shift and 64 or self.ctrl and 10 or 1
    self.count=tostring(util.clamp((tonumber(self.count) or 0)+direction*step,1,2304))
    self.dirty=true self:draw()
end
function Panel:mutate(operation,payload)
    if self.pending then return end
    local session=self.session
    self.revision=self.revision+1
    self.pending=true self.message="Сохранение…" self.bad=false
    self:draw()
    self.request(operation,payload,function(ok,data,err)
        if not self.open or self.session~=session then return end
        self.pending=false
        if ok then self.candidate=nil self.dirty=false self:apply(data) self.message="Сохранено"
        else self.message=tostring(err or "Ошибка сохранения") self.bad=true end
        self:draw()
    end)
end
function Panel:save()
    local rule=self.rules[self.selected]
    if not rule then return end
    local count=tonumber(self.count)
    if not count or count%1~=0 or count<1 or count>2304 then self.message="Количество: от 1 до 2304" self.bad=true self:draw() return end
    self:mutate("restock_set",{id=rule.id,name=rule.name,label=rule.label,count=count,enabled=rule.enabled})
end
function Panel:change(remove)
    local rule=self.rules[self.selected]
    if not rule or not rule.id then return end
    self:mutate(remove and "restock_remove" or "restock_toggle",{id=rule.id,enabled=not rule.enabled})
end
function Panel:update(now)
    if self.open and not self.pending and not self.pollPending and now>=(self.pollAt or 0) then self:refresh() end
end
function Panel:onEvent(event,...)
    if not self.open then return end
    if event=="rednet_message" or event=="timer" then return end
    local values={}
    for _,value in ipairs({...}) do if type(value)=="number" then values[#values+1]=value end end
    local code=values[1]
    if event=="keyboard_close" then self:close() return true end
    if event=="key" or event=="key_up" then
        if code==keys.leftCtrl or code==keys.rightCtrl then self.ctrl=event=="key" return true end
        if code==keys.leftShift or code==keys.rightShift then self.shift=event=="key" return true end
        if event=="key_up" then return true end
        if code==keys.escape then self:close()
        elseif self.pending then return true
        elseif code==keys.enter then self:save()
        elseif code==keys.backspace and self.focus then self.count=self.count:sub(1,-2) self.dirty=true self:draw()
        elseif code==keys.up or code==keys.down then
            self:select(util.clamp(self.selected+(code==keys.down and 1 or -1),1,math.max(1,#self.rules))) self:draw()
        end
        return true
    elseif event=="char" then
        if self.pending then return true end
        local char=({...})[1]
        if self.focus and type(char)=="string" and char:match("^%d+$") and #self.count+#char<=4 then
            self.count=self.count..char self.dirty=true self:draw()
        end
        return true
    elseif event=="player_mouse_move" and self.scale then
        self.px=util.clamp(self.px+(values[#values-1] or 0),self.x,self.x+360*self.scale)
        self.py=util.clamp(self.py+(values[#values] or 0),self.y,self.y+294*self.scale)
        util.moveTopCursor(self.cursor,self.px,self.py,90)
        local now=util.epoch()
        if now>=(self.flushAt or 0) then self.flushAt=now+25 self.ctx.system.flushOverlay() end
        return true
    elseif event=="player_mouse_scroll" then
        if self.pending then return true end
        local delta=(code or 0)>0 and 1 or -1
        if self.focus then self:adjust(-delta)
        else self:select(util.clamp(self.selected+delta,1,math.max(1,#self.rules))) self:draw() end
        return true
    elseif event=="player_mouse_click" then
        if self.pending then return true end
        if code==0 or code==1 then
            for _,hit in ipairs(self.hits or {}) do
                if self.px>=hit.x and self.px<hit.x+hit.w and self.py>=hit.y and self.py<hit.y+hit.h then hit.run() break end
            end
        end
        return true
    elseif event=="paste" or event=="player_interaction" then return true end
end
return Panel
