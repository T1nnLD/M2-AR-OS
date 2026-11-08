-- Run from the repository root: lua tests/block_search_app.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match('^m2os%.') then
        local path=name:gsub('^m2os%.',''):gsub('%.','/')..'.lua'
        local chunk=loadfile(path) if chunk then return chunk,path end
    end
end)
local util=require('m2os.lib.util')
local now,mode,calls=0,nil,0
os.epoch=function() return now end
keys={enter=1,escape=2,backspace=3,delete=4}
local files,objects,services,actions={},{},{},{}
local width,height,changes=500,350,0
util.readTable=function(path,fallback) return files[path] or fallback end
util.writeTable=function(path,value) files[path]=util.copy(value) return true end
local function object(properties)
    local object={properties=properties or {},removed=false}
    object.setPos=function(x,y,z)
        assert(not object.removed,'cursor must reference a live object')
        object.properties.x,object.properties.y,object.properties.z=x,y,z
    end
    object.setContent=function(value) assert(not object.removed) object.properties.content=value changes=changes+1 end
    object.setColor=function(value) assert(not object.removed) object.properties.color=value changes=changes+1 end
    objects[#objects+1]=object
    return object
end
local ctx={config={theme={white=1,gray=2,purple=3,background=4,red=5,amber=6,yellow=7}},
    ui={remove=function(object) assert(not object.removed) object.removed=true end,
        raw=function(_,properties) return object(properties) end,
        rectangle=function() return object() end,textureRect=function() return object() end,
        text=function(x,y,content) return object({gui=true,x=x,y=y,content=content}) end},
    notify=function() end,
    system={getSize=function() return width,height end,getInputMode=function() return mode end,
        setInputMode=function(value) mode=value end,getEyePosition=function() return 0.25,65.62,0.75 end,
        getModule=function() return {setCaptureMouse=function() end} end,flushOverlay=function() end},
    services={provide=function(name,value) services[name]=value end},menu={add=function(action) actions[action.id]=action end}}
local blocks={{name='minecraft:diamond_ore',x=1.25,y=-1.12,z=-0.25}}
local scanner={scanBlocks=function() calls=calls+1 return blocks end,
    getConfiguration=function() return {operations={scan_blocks={maxFreeRadius=8}}} end}
peripheral={find=function() return scanner,'back' end}
local app=require('m2os.apps.block_search')
app.start(ctx)
actions['block_search.panel'].run()
assert(mode=='block_search' and calls==0,'opening the GUI must not wait for the scanner')
assert(#objects==0,'wait for the Keyboard screen dimensions before the first draw')
app.onEvent(ctx,'paste','minecraft:diamond_ore')
app.onEvent(ctx,'key',keys.enter,false)
assert(calls==0,'Enter must render feedback before any native scan')
now=100 app.update(ctx,now)
assert(#objects==0 and calls==0,'do not flash a panel or begin native work before layout settles')
now=200 app.update(ctx,now)
assert(calls==1 and services.block_search.status().total==1)
local world={}
for _,object in ipairs(objects) do if object.properties.gui==false then world[#world+1]=object end end
assert(#world==12)
local gui={}
for _,object in ipairs(objects) do if object.properties.gui~=false then gui[#gui+1]=object end end
local created=#objects
app.onEvent(ctx,'char','x') -- editing/redrawing the GUI must preserve world objects.
for _,object in ipairs(world) do assert(not object.removed) end
assert(#objects==created,'typing must edit existing text instead of rebuilding the panel and cursor')
blocks[1].x=1.15 -- same block center after grid snapping, new measured distance.
now=5200 app.update(ctx,now)
assert(calls==2 and #objects==created,'refreshing results must reuse the panel, cursor and unchanged markers')
for _,object in ipairs(gui) do assert(not object.removed) end
local before=changes
now=5250 app.update(ctx,now)
assert(changes==before,'idle frames must not send redundant text/color updates')

-- Resize bursts retain the previous clickable layout, then rebuild once
-- using the latest dimensions. Ordinary result updates never re-center it.
local plus
for _,object in ipairs(gui) do if object.properties.content=='+' then plus=object break end end
app.onEvent(ctx,'player_mouse_move',plus.properties.x+1-250,plus.properties.y+1-175)
width,height=800,500
now=5300 app.resize(ctx)
now=5400 app.resize(ctx)
app.onEvent(ctx,'player_mouse_click',1)
assert(services.block_search.status().radius==9,'old buttons must remain clickable while a resize is pending')
now=5500 app.update(ctx,now)
assert(#objects==created and not gui[1].removed)
now=5580 app.update(ctx,now)
assert(gui[1].removed and #objects>created,'build one replacement after the resize burst settles')
app.onEvent(ctx,'player_mouse_click',1)
assert(services.block_search.status().radius==10,'cursor must retain its position relative to the resized panel')
for _,object in ipairs(world) do assert(not object.removed,'resizing must leave world markers intact') end
local bounded=objects[#objects]
for i=1,12 do
    now=5580+i*50 width=800+i
    app.resize(ctx) app.update(ctx,now)
end
assert(bounded.removed,'continuous resize events must not postpone the replacement indefinitely')
app.onEvent(ctx,'key',keys.escape)
assert(mode==nil and services.block_search.status().active)
for _,object in ipairs(world) do assert(not object.removed,'closing the panel must leave highlighting active') end
services.block_search.show()
app.onEvent(ctx,'player_mouse_move','back',10,10)
assert(mode=='block_search','mouse movement before a reopened panel is built must be harmless')
app.onEvent(ctx,'keyboard_close')
blocks={}
now=10200 app.update(ctx,now)
for _,object in ipairs(world) do assert(object.removed,'removed blocks must lose their highlights') end
app.stop(ctx)
assert(not services.block_search.status().active)
app.start(ctx)
actions['block_search.panel'].run()
assert(not services.block_search.status().active,'a restart restores settings without restarting native scanning')
app.onEvent(ctx,'key',keys.enter)
assert(services.block_search.status().query=='minecraft:diamond_ore','restore the last valid ID from disk')
app.stop(ctx)

-- Existing preserved configs must get the app without editing their modules.
fs={exists=function(path) return path=='/m2os/apps/block_search.lua' end}
local Kernel=require('m2os.kernel')
local kernel=setmetatable({config={modules={}},apps={},appOrder={},actions={}},Kernel)
kernel:_loadApps()
assert(kernel.apps.block_search)
print('block search input, GUI/world lifetimes, settings and preserved-config loading tests: OK')
