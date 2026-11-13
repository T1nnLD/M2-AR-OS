-- Run from the repository root: lua tests/kernel_async.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match('^m2os%.') then
        local path=name:gsub('^m2os%.',''):gsub('%.','/')..'.lua'
        local chunk=loadfile(path) if chunk then return chunk,path end
    end
end)
local util=require('m2os.lib.util')
local now,sequence,queued,timers=0,0,{},{}
os.epoch=function() return now end
os.pullEventRaw=function(filter) return coroutine.yield(filter) end
os.queueEvent=function(...) queued[#queued+1]=table.pack(...) end
os.startTimer=function(seconds) sequence=sequence+1 timers[sequence]=now+seconds*1000 return sequence end
os.cancelTimer=function(id) timers[id]=nil end
util.readTable=function(_,fallback) return fallback end
util.writeTable=function() return true end
local flushes,removed=0,0
local screenW,screenH=800,500
local overlay={getGuiSize=function() return screenW,screenH,1 end,setAutoUpdate=function() end,
    getEyePosition=function() return 0,65.62,0 end,update=function() flushes=flushes+1 end,
    removeObject=function() removed=removed+1 end}
local objectID=0
local function create()
    objectID=objectID+1 local id=objectID
    return {getId=function() return id end,setPos=function() end,setColor=function() end,
        setContent=function() end,setImageSize=function() end,setPixel=function() end}
end
for _,kind in ipairs({'Box','Text','Rectangle','Texture'}) do overlay['create'..kind]=create end
smartglasses={modules={overlay=overlay}}
local Kernel=require('m2os.kernel')
local kernel=Kernel.new({name='test',version='async',stateFile='/test',modules={},theme={red=1,green=2}})
kernel._loadApps=function() end
local function waitTask(id)
    while true do local _,value=os.pullEventRaw('task_complete') if value==id then return end end
end
local movement,clicks,frames,native,finished,other,backend,ticks,boots={},{},0,0,0,0,{},0,0
kernel:register({id='gui',persistent=false,start=function(ctx) ctx.system.setInputMode('gui') end,
    update=function() frames=frames+1 end,
    onEvent=function(ctx,event,a,b)
        if event=='key' and a==99 then waitTask(7000) return true end
        if event=='key' and a==100 then ctx.system.stop() return true end
        if event=='player_mouse_move' then movement[#movement+1]={a,b} return true end
        if event=='player_mouse_click' then clicks[#clicks+1]=#movement return true end
    end})
kernel:register({id='sensor',persistent=false,poll=function(ctx)
    native=native+1 waitTask(500+native)
    finished=finished+1 ctx.ui.raw('Box',{gui=false})
end})
kernel:register({id='other_sensor',persistent=false,poll=function() other=other+1 end})
kernel:register({id='logic',persistent=false,logic=function() ticks=ticks+1 end,
    onEvent=function(_,event,_,message)
        if event=='rednet_message' then
            if message.id==1 then waitTask(700) end
            backend[#backend+1]=message.id
        end
    end})
kernel:register({id='slow_start',persistent=false,start=function() waitTask(9999) boots=boots+1 end,
    onEvent=function(_,event) if event=='boot_result' then boots=boots+10 end end})
local function step(event) kernel:_stepRuntime(event) end
local function drain()
    local limit=100
    while #queued>0 do limit=limit-1 assert(limit>0) step(table.remove(queued,1)) end
end
local function advance(to)
    now=to
    local due={}
    for id,deadline in pairs(timers) do if deadline<=now then due[#due+1]=id end end
    table.sort(due)
    for _,id in ipairs(due) do if timers[id] then timers[id]=nil step({'timer',id}) end end
    drain()
end
kernel:_startRuntime() drain()
assert(native==1 and finished==0 and boots==0)
step({'player_mouse_move',3,4}) step({'player_mouse_click',1})
advance(50)
assert(#movement==1 and clicks[1]==1 and frames>0 and other>=2 and ticks>0,
    'UI frames, input, other sensors and logic must continue while a native scan and startup are waiting')
step({'rednet_message',42,{id=1},'test'})
step({'rednet_message',42,{id=2},'test'})
step({'player_mouse_move',1,2}) advance(100)
assert(#movement==2 and #backend==0,'a waiting backend must not block input or prematurely consume the next RPC reply')
step({'boot_result'})
step({'task_complete',9999}) drain()
assert(boots==11,'events arriving during asynchronous startup must wait until initialization completes')
step({'task_complete',700})
assert(#backend==2 and backend[1]==1 and backend[2]==2,'buffered replies must be delivered once in arrival order')

-- Even if a plugin's input callback waits, preserve motion/click ordering and
-- recover the frame timer it consumed. Consecutive deltas may be combined.
step({'key',99})
step({'player_mouse_move',2,0}) step({'player_mouse_move',3,1})
step({'player_mouse_click',1}) step({'player_mouse_move',1,0})
advance(150)
step({'task_complete',7000})
assert(movement[3][1]==5 and movement[3][2]==1 and clicks[2]==3 and movement[4][1]==1)
local previousFrames=frames
advance(200)
assert(frames>previousFrames,'a callback must not permanently swallow the GUI timer')

kernel:setEnabled('sensor',false)
step({'task_complete',501})
assert(finished==0,'disabling must discard a pending sensor result')
kernel:setEnabled('sensor',true)
step({'wake'}) step({'wake'})
assert(native==2)
step({'task_complete',501}) assert(finished==0)
step({'task_complete',502}) assert(finished==1)
local failed=0
kernel:register({id='errors',persistent=false,update=function() end,
    poll=function() failed=failed+1 error('expected sensor failure') end})
kernel:setEnabled('errors',true) drain()
advance(250) advance(300)
assert(failed==3 and not kernel.apps.errors.enabled,'GUI successes must not reset the sensor failure counter')
kernel:setEnabled('errors',true) drain()
assert(failed==4 and kernel.apps.errors.enabled,'re-enabling must start with a fresh failure count')
kernel:setEnabled('errors',false)
local window
kernel:register({id='owned_window',persistent=false,start=function(ctx)
    window=ctx.ui.window({mode='owned_dialog',build=function(w) w:text('label',12,12,'test') end})
    window:show()
end})
kernel:setEnabled('owned_window',true) drain()
advance(500)
assert(window.built and kernel.inputMode=='owned_dialog','kernel must build owned windows automatically')
local x=window.x
screenW=1000 screenH=600 advance(550) advance(700)
assert(window.x==x,'retain stable geometry during a resize burst')
advance(750)
assert(window.x~=x,'kernel must resize a window without app-specific resize callbacks')
kernel:setEnabled('owned_window',false)
assert(not window.open and kernel.inputMode==nil,'disabling an app must close its windows')
kernel:register({id='broken_start',persistent=false,start=function(ctx)
    ctx.system.setInputMode('custom_dialog')
    ctx.services.provide('partial',{})
    ctx.ui.raw('Box',{gui=true})
    error('expected startup failure')
end})
kernel:setEnabled('broken_start',true) drain()
assert(not kernel.apps.broken_start.enabled and kernel.inputMode==nil and not kernel.services.partial,
    'failed initialization must release input and remove partial services/objects')
assert(flushes>0)
step({'key',100}) kernel:_shutdown()
assert(not kernel.running and kernel.inputMode==nil and next(kernel.scheduler.tasks)==nil)
assert(next(kernel.scheduler.timers)==nil and removed==objectID,'shutdown must cancel tasks/timers and remove owned objects')
print('async kernel UI, independent sensors, backend queues, startup and shutdown tests: OK')
