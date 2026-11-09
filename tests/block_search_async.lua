-- Run from the repository root: lua tests/block_search_async.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match('^m2os%.') then
        local path=name:gsub('^m2os%.',''):gsub('%.','/')..'.lua'
        local chunk=loadfile(path) if chunk then return chunk,path end
    end
end)
local util=require('m2os.lib.util')
local now,seq,queue,timers=0,0,{},{}
os.epoch=function() return now end
os.pullEventRaw=function(filter) return coroutine.yield(filter) end
os.queueEvent=function(...) queue[#queue+1]=table.pack(...) end
os.startTimer=function(seconds) seq=seq+1 timers[seq]=now+seconds*1000 return seq end
os.cancelTimer=function(id) timers[id]=nil end
util.readTable=function(_,fallback) return fallback end
util.writeTable=function() return true end
local objects,objectID={},0
local overlay={getGuiSize=function() return 500,350,1 end,
    getEyePosition=function() return 0.25,65.62,0.75 end,setAutoUpdate=function() end,update=function() end,
    removeObject=function(id) assert(objects[id]) objects[id]=nil end,
    createBox=function(properties)
        objectID=objectID+1 local id=objectID objects[id]=properties
        return {getId=function() return id end}
    end}
smartglasses={modules={overlay=overlay}}
local calls,results=0,{}
local scanner={getConfiguration=function() return {operations={scan_blocks={maxFreeRadius=8}}} end}
scanner.scanBlocks=function()
    calls=calls+1 local id=1000+calls
    while true do local _,complete=os.pullEventRaw('task_complete') if complete==id then break end end
    return assert(results[id])
end
peripheral={find=function() return scanner,'back' end}
local Kernel=require('m2os.kernel')
local kernel=Kernel.new({name='test',version='async',modules={},stateFile='/test',
    theme={red=1,green=2,yellow=3},tracker={range=8,intervalMs=100},blockSearch={stateFile=false,maxMarkers=1}})
kernel._loadApps=function() end
local inputs=0
kernel:register({id='input',persistent=false,onEvent=function(_,event)
    if event=='player_mouse_move' then inputs=inputs+1 return true end
end})
kernel:register(require('m2os.apps.block_search'))
local function step(event) kernel:_stepRuntime(event) end
local function drain()
    local limit=100
    while #queue>0 do limit=limit-1 assert(limit>0) step(table.remove(queue,1)) end
end
local function advance(value)
    now=value local due={}
    for id,time in pairs(timers) do if time<=now then due[#due+1]=id end end
    table.sort(due)
    for _,id in ipairs(due) do if timers[id] then timers[id]=nil step({'timer',id}) end end
    drain()
end
kernel:_startRuntime() drain()
local service=kernel.services.block_search.methods
assert(service.start('minecraft:stone')) drain() advance(100)
assert(calls==1)
assert(service.start('minecraft:diamond_ore')) drain() advance(200)
assert(calls==2)
results[1001]={{name='minecraft:stone',x=0.25,y=-0.12,z=-0.25}}
step({'task_complete',1001})
assert(service.status().total==0 and next(objects)==nil,'a late cancelled scan must not publish old markers')
results[1002]={}
for i=1,300 do results[1002][i]={name='minecraft:stone',x=0.25,y=-0.12,z=-0.25} end
results[1002][301]={name='minecraft:diamond_ore',x=1.25,y=-1.12,z=-0.25}
step({'task_complete',1002})
assert(service.status().total==0,'large scan processing must yield before completing')
step({'player_mouse_move',1,1})
assert(inputs==1,'GUI input must run while a large result is being processed')
drain()
assert(service.status().total==1 and service.status().nearest.blockX==1)
local count=0 for _ in pairs(objects) do count=count+1 end assert(count==12)
service.stop()
advance(1000)
assert(not service.status().active and calls==2 and next(objects)==nil,'Stop must cancel polling and clear its results')
step({'terminate'}) kernel:_shutdown()
assert(next(kernel.scheduler.tasks)==nil and next(objects)==nil)
print('async block search query cancellation, yielding result processing and Stop tests: OK')
