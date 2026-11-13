local util=require("m2os.lib.util")
local Window=require("m2os.lib.window")
local Panel={}
Panel.__index=Panel
local ROWS=5
function Panel.new(ctx,request)
    local self=setmetatable({ctx=ctx,request=request,open=false},Panel)
    local options={width=360,height=294,mode="restock",
        build=function(window) self:build(window) end,
        update=function(window) self:updateContents(window) end,
        onClose=function() self.open=false self.session=nil end}
    self.window=ctx.ui.window and ctx.ui.window(options) or Window.new(ctx,options)
    return self
end
function Panel:build(window)
    local theme=self.ctx.config.theme
    window:text(nil,12,10,"АВТОПОПОЛНЕНИЕ",theme.white,1)
    window:text(nil,12,28,"На складе: наведи на предмет и нажми K",theme.gray,0.72)
    for row=1,ROWS do
        local offset=row
        window:button("row"..row,12,45+(row-1)*23,336,21,"",function()
            self:select(math.floor((self.selected-1)/ROWS)*ROWS+offset) self:draw()
        end)
    end
    window:text("item",12,166,"",theme.gray,0.70)
    window:text(nil,12,180,"Считается общий остаток по ID, включая все варианты",theme.gray,0.66)
    window:text(nil,12,201,"Держать минимум:")
    window:button("count",144,195,90,21,"",function() self.focus=true self:draw() end)
    window:button("minus",240,195,47,21,"-",function() self:adjust(-1) end)
    window:button("plus",293,195,55,21,"+",function() self:adjust(1) end)
    window:button("save",12,224,108,21,"Сохранить",function() self:save() end)
    window:button("toggle",126,224,108,21,"",function() self:change(false) end)
    window:button("remove",240,224,108,21,"Удалить",function() self:change(true) end)
    window:text("status",12,252,"",theme.gray,0.72)
    window:text(nil,12,274,"Enter: сохранить · Колесо/↑↓: правило · Esc: закрыть",theme.gray,0.66)
end
function Panel:updateContents(window)
    local theme=self.ctx.config.theme
    local page=math.floor((self.selected-1)/ROWS)
    for row=1,ROWS do
        local index=page*ROWS+row
        local rule=self.rules[index]
        local id="row"..row
        window:set(id..".label","setContent",rule and
            (util.short((rule.enabled and "+ " or "- ")..rule.label,35).." ≥"..rule.count) or "")
        window:set(id..".background","setColor",index==self.selected and theme.purple or 0x293044)
        window:set(id..".background","setOpacity",rule and 1 or 0)
        window:enableButton(id,rule~=nil and not self.pending)
    end
    local rule=self.rules[self.selected]
    window:set("item","setContent",util.short(rule and rule.name or "Выбери предмет на складе клавишей K",53))
    window:set("count.label","setContent",(self.focus and "> " or "")..self.count)
    window:set("count.background","setColor",self.focus and theme.purple or 0x293044)
    window:set("toggle.label","setContent",rule and rule.enabled and "Выключить" or "Включить")
    for _,id in ipairs({"count","minus","plus","save","toggle","remove"}) do window:enableButton(id,not self.pending) end
    local telemetry=rule and ((rule.current~=nil and ("Остаток: "..rule.current..". ") or "")..(rule.message or "")) or ""
    window:set("status","setContent",util.short(self.message or telemetry,53))
    window:set("status","setColor",self.bad and theme.red or theme.gray)
end
function Panel:draw() self.window:draw() end
function Panel:frame(now) self.window:update(now) end
function Panel:resize() self.window:resize() end
function Panel:failure(err)
    local message=tostring(err or "Ошибка запроса")
    local lower=message:lower()
    if lower:find("unknown operation",1,true) or lower:find("unknow operation",1,true)
            or lower:find("нужна версия 12",1,true) then
        self.unsupported=true
        return "Обнови и перезапусти мост хранилища (версия 12+)"
    end
    return message
end
function Panel:bridgeReady()
    self.unsupported=false
    if self.open then self.pollAt=0 end
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
        else self.message=self:failure(err) self.bad=true end
        self:draw()
    end)
end
function Panel:show(item)
    self.open=true self.session={}
    self.revision=0
    self.rules={} self.selected=1 self.count="64" self.focus=false self.dirty=false
    self.pending=false self.candidate=item and util.copy(item) or nil
    self.unsupported=false
    self.message="Чтение правил…" self.bad=false
    self.ctrl,self.shift=false,false
    self.window:show()
    self:refresh(self.candidate)
end
function Panel:close()
    self.open=false self.session=nil
    self.window:close()
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
        else self.message=self:failure(err) self.bad=true end
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
    if self.open and not self.unsupported and not self.pending and not self.pollPending and now>=(self.pollAt or 0) then self:refresh() end
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
    elseif event=="player_mouse_move" then
        self.window:move(values[#values-1] or 0,values[#values] or 0)
        return true
    elseif event=="player_mouse_scroll" then
        if self.pending then return true end
        local delta=(code or 0)>0 and 1 or -1
        if self.focus then self:adjust(-delta)
        else self:select(util.clamp(self.selected+delta,1,math.max(1,#self.rules))) self:draw() end
        return true
    elseif event=="player_mouse_click" then
        if self.pending then return true end
        self.window:click(code)
        return true
    elseif event=="paste" or event=="player_interaction" then return true end
end
return Panel
