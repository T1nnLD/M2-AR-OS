-- Run from the repository root: lua tests/scheduler.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match('^m2os%.') then
        local path=name:gsub('^m2os%.',''):gsub('%.','/')..'.lua'
        local chunk=loadfile(path) if chunk then return chunk,path end
    end
end)
local Scheduler=require('m2os.lib.scheduler')
local queue,timers,cancelled,errors={},{},{},{}
local sequence=0
os.pullEventRaw=function(filter) return coroutine.yield(filter) end
os.queueEvent=function(...) queue[#queue+1]=table.pack(...) end
os.startTimer=function() sequence=sequence+1 timers[sequence]=true return sequence end
os.cancelTimer=function(id) cancelled[id]=true timers[id]=nil end
local scheduler=Scheduler.new(function(task,err) errors[#errors+1]={task.id,err} end)
local inputs,replies,reads={},0,0
scheduler:spawn('sensor',function()
    local event,id=os.pullEventRaw('task_complete')
    assert(event=='task_complete' and id==7)
    reads=reads+1
end,{owner='sensor',priority=100})
scheduler:spawn('input',function()
    while true do local event,value=os.pullEventRaw() inputs[#inputs+1]={event,value} end
end,{owner='gui',priority=0})
scheduler:spawn('logic',function()
    local event=os.pullEventRaw('rednet_message')
    assert(event=='rednet_message') replies=replies+1
end,{owner='logic'})
scheduler:step()
scheduler:step({'player_mouse_move',4,5})
scheduler:step({'rednet_message',42,{id=1}})
assert(#inputs==2 and replies==1 and reads==0,'a pending sensor must not swallow input or network replies')
scheduler:step({'task_complete',7})
assert(reads==1 and scheduler.tasks.sensor==nil)

local old,new=false,false
scheduler:spawn('replace',function() os.pullEventRaw('old') old=true end,{owner='app'})
scheduler:step()
scheduler:spawn('replace',function() os.pullEventRaw('new') new=true end,{owner='app'})
scheduler:step({'old'})
assert(not old and not new,'cancelled task must never resume on a late reply')
scheduler:step({'new'}) assert(new)
scheduler:spawn('timer',function() scheduler:sleep(1) error('must be cancelled') end,{owner='app'})
scheduler:step()
local timer=scheduler.tasks.timer.timer
assert(scheduler:isInternal({'timer',timer}))
scheduler:cancelOwner('app')
assert(cancelled[timer] and not scheduler:isInternal({'timer',timer}))
scheduler:step({'timer',timer})
assert(#errors==0)

local yielded=false
scheduler:spawn('cooperate',function() scheduler:yield() yielded=true end,{owner='app'})
scheduler:step()
assert(not yielded and #queue==1)
scheduler:step(table.remove(queue,1))
assert(yielded)
scheduler:spawn('broken',function() error('test failure') end,{owner='bad'})
scheduler:step()
assert(#errors==1 and errors[1][1]=='broken' and scheduler.tasks.input,'an error must not kill unrelated tasks')
scheduler:cancelAll()
assert(next(scheduler.tasks)==nil and next(scheduler.timers)==nil)
print('scheduler event fan-out, cancellation, timers, cooperation and error isolation tests: OK')
