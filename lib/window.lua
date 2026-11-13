-- Shared modal window: stable geometry, retained widgets and a persistent
-- cursor. Only a settled resize rebuilds its objects.
local util=require("m2os.lib.util")
local Window={}
Window.__index=Window

function Window.new(ctx,options)
    options=options or {}
    return setmetatable({ctx=ctx,options=options,width=options.width or 360,height=options.height or 294,
        mode=options.mode or (ctx.app and ctx.app.id),objects={},widgets={},cache={},hits={},hitById={},open=false},Window)
end

function Window:_clear()
    for _,object in ipairs(self.objects) do self.ctx.ui.remove(object) end
    self.objects={} self.widgets={} self.cache={} self.hits={} self.hitById={}
    self.built=false self.cursor=nil
end

function Window:show()
    if self.open then return self:draw() end
    self.open=true self.px=nil self.py=nil
    self.resizeStartedAt=util.epoch()
    self.drawAt=self.resizeStartedAt+180
    if self.mode then self.ctx.system.setInputMode(self.mode) end
end

function Window:close()
    local wasOpen=self.open
    self.open=false self.drawAt=nil self.resizeStartedAt=nil
    self:_clear()
    if self.mode and self.ctx.system.getInputMode()==self.mode then self.ctx.system.setInputMode(nil) end
    if wasOpen and self.options.onClose then self.options.onClose(self) end
end

function Window:_keep(id,object,initial)
    self.objects[#self.objects+1]=object
    if id then self.widgets[id]=object self.cache[id]=initial or {} end
    return object
end

function Window:text(id,x,y,value,color,size)
    color=color or self.ctx.config.theme.white
    return self:_keep(id,self.ctx.ui.text(self.x+x*self.scale,self.y+y*self.scale,value,
        color,(size or 0.76)*self.scale,76,false),{setContent=value,setColor=color})
end

function Window:rectangle(id,x,y,width,height,color,opacity,z)
    opacity=opacity or 1
    return self:_keep(id,self.ctx.ui.rectangle(self.x+x*self.scale,self.y+y*self.scale,
        width*self.scale,height*self.scale,color,opacity,z or 73),{setColor=color,setOpacity=opacity})
end

function Window:button(id,x,y,width,height,label,run,color)
    self:rectangle(id..".background",x,y,width,height,color or 0x293044)
    self:text(id..".label",x+4,y+5,label)
    local hit={id=id,x=self.x+x*self.scale,y=self.y+y*self.scale,
        w=width*self.scale,h=height*self.scale,run=run,enabled=true}
    self.hits[#self.hits+1]=hit self.hitById[id]=hit
end

function Window:set(id,method,value)
    local object=self.widgets[id]
    if not object then return end
    local cache=self.cache[id]
    if cache[method]~=value then object[method](value) cache[method]=value end
end

function Window:enableButton(id,enabled)
    local hit=self.hitById[id]
    if hit then hit.enabled=enabled==true end
end

function Window:_build()
    local px,py
    if self.scale and self.px and self.py then
        px=(self.px-self.x)/self.scale py=(self.py-self.y)/self.scale
    end
    self:_clear()
    local width,height=self.ctx.system.getSize()
    self.scale=math.max(0.1,math.min(1,(width-12)/self.width,(height-12)/self.height))
    self.x=(width-self.width*self.scale)/2 self.y=(height-self.height*self.scale)/2
    self.px=util.clamp(px and self.x+px*self.scale or width/2,self.x,self.x+self.width*self.scale)
    self.py=util.clamp(py and self.y+py*self.scale or height/2,self.y,self.y+self.height*self.scale)
    local theme=self.ctx.config.theme
    self:_keep(nil,self.ctx.ui.textureRect(self.x,self.y,self.width*self.scale,self.height*self.scale,theme.background,1,70))
    self:rectangle(nil,0,0,self.width,2,theme.purple,1,72)
    if self.options.build then self.options.build(self) end
    local ui={raw=function(kind,properties) return self:_keep(nil,self.ctx.ui.raw(kind,properties)) end}
    self.cursor=util.createTopCursor(ui,self.px,self.py,90,theme)
    self.built=true
end

function Window:draw(flush)
    if not self.open then return end
    local ok,err=pcall(function()
        if not self.built then
            if self.drawAt then return end
            self:_build()
        end
        if self.options.update then self.options.update(self) end
        if flush~=false then self.ctx.system.flushOverlay() end
    end)
    if not ok then
        self:close()
        self.ctx.notify("Ошибка окна: "..tostring(err),self.ctx.config.theme.red)
    end
    return ok
end

function Window:update(now)
    if not self.open then return end
    if self.drawAt and now>=self.drawAt then
        self.drawAt=nil self.resizeStartedAt=nil
        self.built=false
        self:draw()
    else self:draw(false) end
end

function Window:resize()
    if not self.open then return end
    local now=util.epoch()
    self.resizeStartedAt=self.resizeStartedAt or now
    self.drawAt=math.min(now+180,self.resizeStartedAt+500)
end

function Window:move(dx,dy)
    if not self.built then return end
    self.px=util.clamp(self.px+dx,self.x,self.x+self.width*self.scale)
    self.py=util.clamp(self.py+dy,self.y,self.y+self.height*self.scale)
    util.moveTopCursor(self.cursor,self.px,self.py,90)
    local now=util.epoch()
    if now>=(self.flushAt or 0) then self.flushAt=now+25 self.ctx.system.flushOverlay() end
end

function Window:click(button)
    if not self.built or (button~=0 and button~=1) then return end
    for _,hit in ipairs(self.hits) do
        if hit.enabled and self.px>=hit.x and self.px<hit.x+hit.w and self.py>=hit.y and self.py<hit.y+hit.h then
            hit.run() self:draw() return true
        end
    end
end

function Window:onEvent(event,...)
    if not self.open then return end
    local numbers={}
    for _,value in ipairs({...}) do if type(value)=="number" then numbers[#numbers+1]=value end end
    if event=="keyboard_close" or (event=="key" and numbers[1]==keys.escape) then self:close() return true
    elseif event=="player_mouse_move" then self:move(numbers[#numbers-1] or 0,numbers[#numbers] or 0) return true
    elseif event=="player_mouse_click" then self:click(numbers[1]) return true end
end

return Window
