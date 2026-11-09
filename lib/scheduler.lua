-- Cooperative CC event fan-out. A task waiting for task_complete cannot eat
-- input, timers or RPC replies intended for another task.
local Scheduler={}
Scheduler.__index=Scheduler
local WAKE="m2os_async_wake"

function Scheduler.new(onError)
    return setmetatable({tasks={},timers={},sequence=0,onError=onError},Scheduler)
end

function Scheduler:_wake()
    if not self.wakePending then self.wakePending=true os.queueEvent(WAKE) end
end

function Scheduler:cancel(id)
    local task=self.tasks[id]
    if not task then return false end
    self.tasks[id]=nil
    if task.timer then
        self.timers[task.timer]=nil
        if os.cancelTimer then os.cancelTimer(task.timer) end
        task.timer=nil
    end
    return true
end

function Scheduler:cancelOwner(owner)
    local ids={}
    for id,task in pairs(self.tasks) do if task.owner==owner then ids[#ids+1]=id end end
    for _,id in ipairs(ids) do self:cancel(id) end
end

function Scheduler:cancelAll()
    local ids={}
    for id in pairs(self.tasks) do ids[#ids+1]=id end
    for _,id in ipairs(ids) do self:cancel(id) end
end

function Scheduler:spawn(id,callback,options)
    assert(type(id)=="string" and type(callback)=="function","task needs a name and callback")
    options=options or {}
    self:cancel(id)
    self.sequence=self.sequence+1
    self.tasks[id]={id=id,owner=options.owner,priority=options.priority or 100,
        sequence=self.sequence,thread=coroutine.create(callback),started=false}
    self:_wake()
    return id
end

function Scheduler:timer(seconds)
    local task=assert(self.current,"timer must be created from a scheduled task")
    assert(self.tasks[task.id]==task,"task was cancelled")
    if task.timer then
        self.timers[task.timer]=nil
        if os.cancelTimer then os.cancelTimer(task.timer) end
    end
    local id=os.startTimer(seconds)
    task.timer=id
    self.timers[id]=task
    return id
end

function Scheduler:sleep(seconds)
    local timer=self:timer(seconds)
    while true do
        local event,id=os.pullEventRaw("timer")
        if event=="timer" and id==timer then return end
    end
end

function Scheduler:yield()
    assert(self.current,"yield must be called from a scheduled task")
    self:_wake()
    return coroutine.yield(WAKE)
end

function Scheduler:isInternal(event)
    return event[1]==WAKE or (event[1]=="timer" and self.timers[event[2]]~=nil)
end

function Scheduler:step(event)
    if event then
        if event[1]==WAKE then self.wakePending=false end
        if event[1]=="timer" then
            local task=self.timers[event[2]]
            if task then task.timer=nil self.timers[event[2]]=nil end
        end
    end
    local ready={}
    for _,task in pairs(self.tasks) do ready[#ready+1]=task end
    table.sort(ready,function(a,b)
        if a.priority~=b.priority then return a.priority<b.priority end
        return a.sequence<b.sequence
    end)
    for _,task in ipairs(ready) do
        if self.tasks[task.id]==task and (not task.started
                or (event and (task.filter==nil or task.filter==event[1]))) then
            self.current=task
            local result
            if not task.started then task.started=true result=table.pack(coroutine.resume(task.thread))
            else result=table.pack(coroutine.resume(task.thread,table.unpack(event,1,event.n or #event))) end
            self.current=nil
            -- Cancellation/replacement can happen from inside a callback.
            -- Never remove a new task which happens to have the same ID.
            if self.tasks[task.id]==task then
                if not result[1] then
                    self:cancel(task.id)
                    if self.onError then self.onError(task,result[2]) else error(result[2],0) end
                elseif coroutine.status(task.thread)=="dead" then self:cancel(task.id)
                else task.filter=result[2] end
            end
        end
    end
end

return Scheduler
