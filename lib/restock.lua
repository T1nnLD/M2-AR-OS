-- Minimum inventory quantities, owned by the Inventory Manager's memory card.
-- Discovery/counting uses list(), never getItemDetail or Stock Ticker requests.
local util=require("m2os.lib.util")
local Restock={}
Restock.__index=Restock
local function quantity(value)
    value=tonumber(value)
    return value and value==value and value%1==0 and value>=1 and value<=2304 and value or nil
end
local function validName(value)
    return type(value)=="string" and value:match("^[%w_.-]+:[%w_./-]+$")~=nil
end
local function countItem(slots,name)
    local count=0
    for _,stack in pairs(slots) do
        if type(stack)=="table" and stack.name==name then count=count+math.max(0,tonumber(stack.count) or 0) end
    end
    return count
end

function Restock.new(config)
    local path=config.restockFile
    if path==nil then path="/m2os/restock.cfg" end
    local rules={}
    if path then
        if fs.exists(path..".bak") and not fs.exists(path) then fs.move(path..".bak",path) end
        local ok,saved=pcall(util.readTable,path,{})
        if ok and type(saved)=="table" and saved.version==1 and type(saved.rules)=="table" then
            for _,rule in ipairs(saved.rules) do
                if #rules<32 and type(rule)=="table" and validName(rule.name) and quantity(rule.count)
                        and type(rule.owner)=="string" and #rule.owner>0 and #rule.owner<=80 then
                    local id=rule.owner.."|"..rule.name
                    local duplicate=false
                    for _,prior in ipairs(rules) do if prior.id==id then duplicate=true end end
                    if not duplicate then rules[#rules+1]={id=id,name=rule.name,owner=rule.owner,
                        ownerName=type(rule.ownerName)=="string" and rule.ownerName or rule.owner,
                        label=type(rule.label)=="string" and util.short(rule.label,64) or rule.name,
                        count=quantity(rule.count),enabled=rule.enabled==true} end
                end
            end
        end
    end
    local interval=math.max(2000,math.min(60000,tonumber(config.restockIntervalMs) or 5000))
    local delay=math.max(1000,math.min(120000,tonumber(config.restockStartDelayMs) or 10000))
    return setmetatable({path=path,rules=rules,interval=interval,cursor=0,
        nextAt=util.epoch()+delay,telemetry={}},Restock)
end

function Restock:save(rules)
    if not self.path then return false,"Сохранение автопополнения отключено в настройках моста" end
    local temp,backup=self.path..".m2tmp",self.path..".bak"
    local ok,written,err=pcall(util.writeTable,temp,{version=1,rules=rules})
    if not ok or not written then
        if fs.exists(temp) then pcall(fs.delete,temp) end
        return false,"Не удалось сохранить: "..tostring(ok and err or written)
    end
    local replaced,reason=pcall(function()
        if fs.exists(backup) then fs.delete(backup) end
        if fs.exists(self.path) then fs.move(self.path,backup) end
        fs.move(temp,self.path)
    end)
    if not replaced then
        if fs.exists(backup) and not fs.exists(self.path) then pcall(fs.move,backup,self.path) end
        if fs.exists(temp) then pcall(fs.delete,temp) end
        return false,"Не удалось заменить файл: "..tostring(reason)
    end
    self.rules=rules
    self.job=nil
    if fs.exists(backup) then pcall(fs.delete,backup) end
    return true,self:status()
end

function Restock:status()
    local rules=util.copy(self.rules)
    for _,rule in ipairs(rules) do
        local status=self.telemetry[rule.id] or {}
        rule.current=status.current
        rule.message=not rule.enabled and "Выключено" or self.unavailable or status.message or "Ожидание проверки"
    end
    return {rules=rules,intervalMs=self.interval}
end

function Restock:set(payload,manager)
    if not validName(payload.name) or not quantity(payload.count) then
        return false,"Укажи ID предмета и целое количество от 1 до 2304"
    end
    if not manager or type(manager.getOwner)~="function" then return false,"Нужен Inventory Manager с картой игрока" end
    local ok,owner,ownerName=pcall(manager.getOwner)
    if not ok or type(owner)~="string" or owner=="" then return false,"Игрок не в сети или карта не привязана" end
    local rules=util.copy(self.rules)
    local id=owner.."|"..payload.name
    local index
    for i,rule in ipairs(rules) do if rule.id==id then index=i break end end
    if payload.id and payload.id~=id then return false,"Это правило принадлежит другому игроку" end
    if not index and #rules>=32 then return false,"Достигнут предел: 32 правила" end
    rules[index or #rules+1]={id=id,name=payload.name,owner=owner,ownerName=tostring(ownerName or owner),
        label=util.short(tostring(payload.label or payload.name),64),
        count=quantity(payload.count),enabled=payload.enabled~=false}
    return self:save(rules)
end

function Restock:edit(id,enabled,remove)
    local rules=util.copy(self.rules)
    for i,rule in ipairs(rules) do
        if rule.id==id then
            if remove then table.remove(rules,i) else rule.enabled=enabled==true end
            local ok,data=self:save(rules)
            if ok and remove then self.telemetry[id]=nil end
            return ok,data
        end
    end
    return false,"Правило не найдено; обнови список"
end

function Restock:finish(rule,now,message,current,delay)
    self.telemetry[rule.id]={message=message,current=current,nextAt=now+(delay or self.interval)}
    self.job=nil
end

function Restock:tick(now,state)
    if now<self.nextAt then return end
    self.nextAt=now+500
    if state.peripheralRefreshAt or not state.manager then
        self.job=nil
        self.unavailable=state.peripheralRefreshAt and "Ожидание подключения сети" or "Inventory Manager не подключён"
        return
    end
    self.unavailable=nil
    if self.job and self.job.manager~=state.manager then self.job=nil end
    if not self.job then
        local rule
        for offset=1,#self.rules do
            local index=(self.cursor+offset-1)%#self.rules+1
            local candidate=self.rules[index]
            local status=self.telemetry[candidate.id]
            if candidate.enabled and (not status or now>=(status.nextAt or 0)) then
                rule=candidate self.cursor=index break
            end
        end
        if not rule then return end
        local ok,owner=pcall(state.manager.getOwner)
        if not ok or owner~=rule.owner then
            self:finish(rule,now,"Ожидание владельца карты",nil,30000) return
        end
        self.job={rule=rule,manager=state.manager,phase="count",source=1}
        return
    end
    local job=self.job
    local rule=job.rule
    if not rule.enabled then self.job=nil return end
    if job.phase=="count" then
        local ok,slots=pcall(state.manager.list)
        if not ok or type(slots)~="table" then self:finish(rule,now,"Не удалось прочитать инвентарь",nil,30000) return end
        job.current=countItem(slots,rule.name)
        if job.current>=rule.count then self:finish(rule,now,"В наличии",job.current) return end
        if #state.inventories==0 then self:finish(rule,now,"Нет подключённых хранилищ",job.current) return end
        job.phase="source"
        self.telemetry[rule.id]={message="Поиск на складе",current=job.current}
        return
    end
    local inventory=state.inventories[job.source]
    if not inventory then self:finish(rule,now,"Нет предмета на складе",job.current) return end
    job.source=job.source+1
    local ok,slots=pcall(inventory.peripheral.list)
    if not ok or type(slots)~="table" then self:finish(rule,now,"Хранилище недоступно",job.current,30000) return end
    local slot,stack
    for key,item in pairs(slots) do
        local index=tonumber(key)
        if index and type(item)=="table" and item.name==rule.name and (tonumber(item.count) or 0)>0
                and (not slot or index<slot) then slot=index stack=item end
    end
    if not slot then return end
    -- Recheck both the owner and live quantity immediately before delivery.
    -- No queued orders survive this cycle, so delayed polls cannot duplicate it.
    local ownerOk,owner=pcall(state.manager.getOwner)
    if not ownerOk or owner~=rule.owner then self:finish(rule,now,"Владелец карты изменился",nil,30000) return end
    local listed,current=pcall(state.manager.list)
    if not listed or type(current)~="table" then self:finish(rule,now,"Инвентарь недоступен",nil,30000) return end
    local have=countItem(current,rule.name)
    local need=math.min(64,rule.count-have,tonumber(stack.count) or 0)
    if need<=0 then self:finish(rule,now,"В наличии",have) return end
    local movedOk,moved=pcall(state.manager.importItem,inventory.name,{name=rule.name,fromSlot=slot,count=need})
    if not movedOk or type(moved)~="number" or moved<=0 then
        self:finish(rule,now,movedOk and "Нет места или источник изменился" or "Ошибка передачи: "..tostring(moved),have,30000)
        return
    end
    if state.onRestock then state.onRestock(inventory) end
    self:finish(rule,now,("Пополнено: +%d"):format(moved),have+moved)
end

return Restock
