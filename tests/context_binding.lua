-- Run from the repository root: lua tests/context_binding.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match("^m2os%.") then
        local path=name:gsub("^m2os%.",""):gsub("%.","/")..".lua"
        local chunk=loadfile(path)
        if chunk then return chunk,path end
    end
end)
local Binding=require("m2os.lib.context_binding")
local mode,now,requests,texts,bound,closed=nil,0,{},{},nil,0
os.epoch=function() return now end
keys={escape=1,enter=2,up=3,down=4}
local function object() return {setPos=function() end} end
local ctx={config={theme={white=1,gray=2,purple=3,background=4,red=5,green=6}},
    ui={clear=function() texts={} end,rectangle=object,textureRect=object,raw=object,
        text=function(_,_,value) texts[value]=true return object() end},
    notify=function() end,
    system={getSize=function() return 400,280 end,getInputMode=function() return mode end,
        setInputMode=function(value) mode=value end,flushOverlay=function() end},
    services={get=function() return {request=function(operation,payload,callback)
        requests[#requests+1]={operation=operation,payload=payload,callback=callback}
    end} end}}
local panel=Binding.new(ctx,function(target) bound=target end,function() closed=closed+1 end)
local target={name="minecraft:chest",dimension="minecraft:overworld",x=10,y=64,z=-20}
panel:show(target)
assert(mode=='context' and panel.pending and requests[1].operation=='context_discover')
target.x=99
assert(panel.target.x==10,'freeze the target while a selection is open')
panel:onEvent('key',keys.enter,false)
assert(#requests==1,'ignore confirmation until discovery has completed')
requests[1].callback(true,{providers={{name='minecraft:chest_0'},{name='minecraft:chest_1'}}})
panel:onEvent('key','back',keys.down,false)
panel:onEvent('key','back',keys.enter,false)
assert(requests[2].operation=='context_bind' and requests[2].payload.provider=='minecraft:chest_1')
assert(requests[2].payload.x==10 and requests[2].payload.z==-20)
panel:onEvent('player_mouse_click',1)
assert(#requests==2,'rapid clicks must not submit duplicate writes')
requests[2].callback(false,nil,'out of space')
assert(panel.bad and not panel.done and not bound,'failed save must not report success')
panel:onEvent('key',keys.enter,false)
requests[3].callback(true,{provider='minecraft:chest_1'})
assert(panel.done and bound.x==10 and mode=='context')
panel:onEvent('keyboard_close')
assert(not panel.open and mode==nil and closed==1)

-- A stale reply must not modify a new modal session.
panel:show(target)
local stale=requests[#requests].callback
panel:close()
panel:show(target)
stale(true,{providers={{name='stale'}}})
assert(#panel.items==0 and panel.pending)
requests[#requests].callback(true,{providers={{name='block_reader_0'}}})
local row=panel.visible[1]
panel:onEvent('player_mouse_move','back',row.x+2-panel.pointerX,row.y+2-panel.pointerY)
panel:onEvent('player_mouse_click','back',1)
assert(requests[#requests].payload.provider=='block_reader_0','mouse selection must match the rendered row')
panel:onEvent('key',keys.escape,false)
assert(not panel.open and mode==nil)

-- The app exposes the workflow through its radial action and keeps the last
-- inspected target after the five-second information card has expired.
local app=require('m2os.apps.context')
local actions,services={},{}
ctx.menu={add=function(action) actions[action.id]=action end}
local originalGet=ctx.services.get
ctx.services.provide=function(name,value) services[name]=value end
ctx.services.get=function(name)
    if name=='storage' then
        local service=originalGet(name)
        service.inspect=function(_,callback) callback(true,{message='info'}) end
        return service
    end
    return services[name]
end
ctx.config.context={dimension='minecraft:overworld',visibleSeconds=5}
ctx.system.getModule=function() return {setHandlingInteraction=function() end} end
app.start(ctx)
app.onEvent(ctx,'player_interaction',1,target)
now=6000
app.update(ctx,now)
actions['context.bind'].run()
assert(mode=='context' and requests[#requests].payload.x==99)
app.onEvent(ctx,'player_interaction',1,{name='minecraft:furnace',x=1,y=2,z=3})
assert(requests[#requests].payload.x==99,'clicking the modal must not change its target')
app.onEvent(ctx,'keyboard_close')
assert(mode==nil)
app.stop(ctx)
print('context binding modal, async callbacks and app handoff tests: OK')
