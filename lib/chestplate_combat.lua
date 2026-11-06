-- Opt-in automatic hand attacks. Shares fresh tracker scans where available.
local Combat = {}
Combat.__index = Combat

function Combat.new(ctx, chest)
    return setmetatable({ctx=ctx,chest=chest,enabled=false,hand=1,blocked={},nextAt=0,
        message="Автоатака выключена"}, Combat)
end

function Combat:setEnabled(enabled)
    self.enabled = enabled == true
    self.pending = nil
    self.blocked = {}
    self.nextAt = 0
    self.message = self.enabled and "Автоатака: поиск мобов" or "Автоатака выключена"
end

function Combat:stop(reason)
    self:setEnabled(false)
    self.message = "Автоатака остановлена: " .. tostring(reason)
end

local function player(entity)
    return entity.name == "minecraft:player" or entity.isPlayer == true
end

local function finite(value)
    value = tonumber(value)
    return value and value == value and math.abs(value) < math.huge and value or nil
end

local function xyz(entity)
    if type(entity) ~= "table" then return end
    local x,y,z = finite(entity.x),finite(entity.y),finite(entity.z)
    if x and y and z then return x,y,z end
end

local function atan2(y,x)
    if x > 0 then return math.atan(y/x) end
    if x < 0 then return math.atan(y/x) + (y >= 0 and math.pi or -math.pi) end
    return y > 0 and math.pi/2 or (y < 0 and -math.pi/2 or 0)
end

function Combat:snapshot(now)
    local services = self.ctx.services
    local shared = services and services.get and services.get("mob_scan")
    if shared then
        local sample = shared.latest()
        if sample and now-sample.at <= 500 then return sample end
        if self.ctx.system.isEnabled and self.ctx.system.isEnabled("mob_tracker") then
            return nil,"Ожидание свежего скана Threat Boxes"
        end
    end
    if self.sample and now-self.sample.at <= 500 then return self.sample end
    if now < (self.scanAt or 0) then return nil,"Ожидание сканера" end
    self.detector = self.detector or peripheral.find("environment_detector") or peripheral.find("environmentDetector")
    if not self.detector then return nil,"Нужен Environment Detector в очках" end
    local config = self.ctx.config.chestplate or {}
    local range = math.max(1,math.min(9,tonumber(config.attackRange) or 8))
    local interval = 1000
    if type(self.detector.getConfiguration) == "function" then
        local ok, data = pcall(self.detector.getConfiguration)
        local operations = ok and type(data)=="table" and data.operations
        for key, operation in pairs(type(operations)=="table" and operations or {}) do
            if tostring(key):lower():gsub("[^a-z]","") == "scanentities" and type(operation)=="table" then
                range = math.min(range,tonumber(operation.maxFreeRadius) or range)
                interval = math.max(interval,(tonumber(operation.defaultCooldown) or 0)+50)
            end
        end
    end
    self.scanAt = now + interval
    local x,y,z = self.ctx.system.getEyePosition()
    if not x or not y or not z then return nil,"Нет позиции очков" end
    local ok, entities, reason = pcall(self.detector.scanEntities,math.floor(range),false)
    if not ok or type(entities) ~= "table" then
        local message = tostring(ok and reason or entities)
        if not message:lower():find("cooldown",1,true) then self:stop(message) end
        return nil,message
    end
    self.sample = {entities=entities,x=x,y=y,z=z,at=now}
    return self.sample
end

function Combat:target(sample)
    local eyeX,eyeY,eyeZ = self.ctx.system.getEyePosition()
    if not eyeX or not eyeY or not eyeZ then return end
    local range = math.max(1,math.min(9,tonumber((self.ctx.config.chestplate or {}).attackRange) or 8))
    local candidates, players = {},{}
    for _, entity in pairs(sample.entities) do
        local x,y,z = xyz(entity)
        if x then
            if player(entity) then
                -- The wearer appears at x=z=0, y=-eyeHeight in a glasses scan.
                -- Never call getOwner(detailed), which decodes inventories.
                local owner = math.abs(x)<0.01 and math.abs(z)<0.01
                    and math.abs(y+(tonumber(entity.eyeHeight) or 1.62))<0.1
                if not owner then players[#players+1]={x=sample.x+x,y=sample.y+y,z=sample.z+z} end
            elseif entity.name ~= "minecraft:armor_stand" and (tonumber(entity.health) or 0)>0 then
                local height = math.max(0.1,math.min(1, (tonumber(entity.eyeHeight) or 1.4)*0.6))
                local tx,ty,tz = sample.x+x-eyeX,sample.y+y+height-eyeY,sample.z+z-eyeZ
                local distance = tx*tx+ty*ty+tz*tz
                if distance > 0.01 and distance <= range*range then
                    candidates[#candidates+1]={entity=entity,x=tx,y=ty,z=tz,distance=distance}
                end
            end
        end
    end
    table.sort(candidates,function(a,b) return a.distance<b.distance end)
    for _, candidate in ipairs(candidates) do
        local safe = true
        for _, human in ipairs(players) do
            if math.abs(human.x-eyeX-candidate.x)<1.5
                    and math.abs(human.z-eyeZ-candidate.z)<1.5
                    and math.abs(human.y-eyeY-candidate.y)<3 then safe=false break end
        end
        if safe then return candidate end
    end
end

function Combat:update(now, online)
    if not self.enabled or not online or now < self.nextAt then return end
    if self.pending then
        local plan = self.pending
        self.pending = nil
        self.nextAt = now + 550
        if now-plan.at > 500 then self.message="Цель устарела — новый скан" return end
        local sample = self:snapshot(now)
        local current = sample and self:target(sample)
        local id = current and (current.entity.uuid or current.entity.id or current.entity.name)
        if not current or id~=plan.id then self.message="Цель сместилась — новое наведение" return end
        local ok,result,code = self.chest:action(plan.hand,"attack")
        if not ok then
            if code == "TOOL_REQUIRED" then
                self.blocked[plan.hand]=true
                self.message="Рука " .. plan.hand .. ": нужен предмет/оружие"
            elseif code == "NO_ENTITY_FOUND" or code == "ACTION_CONFLICT" then
                self.message="Цель сместилась — повтор наведения"
            else self:stop(result) end
        else self.message="Рука " .. plan.hand .. ": удар / " .. tostring(plan.name) end
        return
    end
    local hand
    for offset=0,4 do
        local index=(self.hand+offset-1)%5+1
        if not self.blocked[index] then hand=index break end
    end
    if not hand then self:stop("Заполни руки предметами и включи режим снова") return end
    local sample,message = self:snapshot(now)
    if not sample then self.message=message or self.message self.nextAt=now+250 return end
    local target = self:target(sample)
    if not target then self.message="Нет мобов в радиусе / рядом с целью игрок" self.nextAt=now+250 return end
    local distance = math.sqrt(target.distance)
    local factor = math.max(0,distance-0.55)/distance
    local position = {x=target.x*factor,y=target.y*factor,z=target.z*factor,
        yaw=math.deg(atan2(-target.x,target.z)),
        pitch=-math.deg(atan2(target.y,math.sqrt(target.x*target.x+target.z*target.z)))}
    local ok, reason = self.chest:move(hand,position)
    if not ok then self:stop(reason) return end
    self.hand=hand%5+1
    -- Passenger world positions settle on the following server tick. Attack
    -- on a later update, not in the same callback as smartHandMove.
    self.lastHand,self.lastPosition=hand,position
    self.pending={hand=hand,name=target.entity.name,
        id=target.entity.uuid or target.entity.id or target.entity.name,at=now}
    self.nextAt=now+100
    self.message="Рука " .. hand .. ": наведение на " .. tostring(target.entity.name)
end

return Combat
