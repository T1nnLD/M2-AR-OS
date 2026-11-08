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
util.readTable=function(path,fallback) return files[path] or fallback end
util.writeTable=function(path,value) files[path]=util.copy(value) return true end
local function object(properties)
    local object={properties=properties or {},removed=false}
    object.setPos=function() assert(not object.removed,'cursor must reference a live object') end
    objects[#objects+1]=object
    return object
end
local ctx={config={theme={white=1,gray=2,purple=3,background=4,red=5,amber=6,yellow=7}},
    ui={remove=function(object) assert(not object.removed) object.removed=true end,
        raw=function(_,properties) return object(properties) end,
        rectangle=function() return object() end,textureRect=function() return object() end,
        text=function() return object() end},
    notify=function() end,
    system={getSize=function() return 500,350 end,getInputMode=function() return mode end,
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
app.onEvent(ctx,'paste','minecraft:diamond_ore')
app.onEvent(ctx,'key',keys.enter,false)
assert(calls==0,'Enter must render feedback before any native scan')
now=100 app.update(ctx,now)
assert(calls==1 and services.block_search.status().total==1)
local world={}
for _,object in ipairs(objects) do if object.properties.gui==false then world[#world+1]=object end end
assert(#world==12)
app.onEvent(ctx,'char','x') -- editing/redrawing the GUI must preserve world objects.
for _,object in ipairs(world) do assert(not object.removed) end
app.onEvent(ctx,'key',keys.escape)
assert(mode==nil and services.block_search.status().active)
for _,object in ipairs(world) do assert(not object.removed,'closing the panel must leave highlighting active') end
blocks={}
now=5100 app.update(ctx,now)
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
