local util=require("m2os.lib.util")
local Search={}
Search.__index=Search

function Search.normalize(query)
    if type(query)~="string" then return nil,"Введи ID блока, например minecraft:diamond_ore" end
    query=query:lower():match("^%s*(.-)%s*$")
    local tag=query:sub(1,1)=="#"
    local id=tag and query:sub(2) or query
    if not id:find(":",1,true) then id="minecraft:"..id end
    if #id>128 or not id:match("^[a-z0-9_.-]+:[a-z0-9_./-]+$") then
        return nil,"Нужен ID блока или #тег, например create:item_vault"
    end
    return (tag and "#" or "")..id
end

local function finite(value)
    value=tonumber(value)
    return value and value==value and math.abs(value)<math.huge and value or nil
end

function Search.matches(block,query)
    if type(block)~="table" then return false end
    if query:sub(1,1)~="#" then return block.name==query end
    local tag=query:sub(2)
    if type(block.tags)~="table" then return false end
    if block.tags[tag]==true then return true end
    for _,value in pairs(block.tags) do if value==tag then return true end end
    return false
end

function Search.new(ctx)
    local config=ctx.config.blockSearch or {}
    local tracker=ctx.config.tracker or {}
    return setmetatable({ctx=ctx,active=false,query="",markers={},total=0,shown=0,
        radius=math.max(1,math.floor(finite(tracker.range) or 16)),
        interval=math.max(100,finite(tracker.intervalMs) or 2100),
        maxMarkers=math.max(1,math.min(32,math.floor(tonumber(config.maxMarkers) or 24))),
        message="Введи ID и нажми «Искать»",nextAt=0},Search)
end

function Search:clear()
    for key,parts in pairs(self.markers) do
        for _,part in ipairs(parts) do self.ctx.ui.remove(part) end
        self.markers[key]=nil
    end
    self.shown,self.total=0,0
    self.nearest=nil
    self.expiresAt=nil
end

function Search:start(query)
    local normalized,err=Search.normalize(query)
    if not normalized then return false,err end
    local tracker=self.ctx.config.tracker or {}
    self:clear()
    self.query=normalized
    self.radius=math.max(1,math.floor(finite(tracker.range) or 16))
    self.interval=math.max(100,finite(tracker.intervalMs) or 2100)
    self.scanRange=nil self.scanner=nil self.scannerName=nil
    self.active=true self.bad=false self.message="Поиск запущен…"
    self.nextAt=util.epoch()+100
    return true,normalized
end

function Search:stop(message,bad)
    self.active=false
    self:clear()
    self.message=message or "Поиск остановлен"
    self.bad=bad==true
end

function Search:configure()
    self.scanner,self.scannerName=peripheral.find("geo_scanner")
    if not self.scanner then self.scanner,self.scannerName=peripheral.find("geoScanner") end
    if not self.scanner then self:stop("Geo Scanner в очках не найден",true) return false end
    if type(self.scanner.scanBlocks)~="function" then self:stop("Нужен Geo Scanner с API scanBlocks (AP 0.8)",true) return false end
    self.scanRange=self.radius
    local freeKnown=false
    if type(self.scanner.getConfiguration)=="function" then
        local ok,config=pcall(self.scanner.getConfiguration)
        local operations=ok and type(config)=="table" and config.operations
        for key,operation in pairs(type(operations)=="table" and operations or {}) do
            if tostring(key):lower():gsub("[^a-z]","")=="scanblocks" and type(operation)=="table" then
                local free=finite(operation.maxFreeRadius)
                local maximum=finite(operation.maxCostRadius)
                if free and free<1 then self:stop("На сервере отключён бесплатный радиус Geo Scanner",true) return false end
                if free then self.scanRange=math.min(self.scanRange,math.floor(free)) freeKnown=true end
                if maximum then self.scanRange=math.min(self.scanRange,math.floor(maximum)) end
                self.interval=math.max(self.interval,(finite(operation.defaultCooldown) or 0)+50)
            end
        end
    end
    -- Older scanners without limits must not receive the entity tracker's
    -- potentially huge radius before their block-scan capability is known.
    if not freeKnown then self.scanRange=math.min(self.scanRange,8) end
    if self.scanRange<1 then self:stop("Сервер не разрешает сканирование",true) return false end
    return true
end

function Search:marker(center)
    local parts={}
    local half,thickness=0.51,0.025
    local color=self.ctx.config.theme.yellow or 0xFFD54A
    local function edge(x,y,z,sx,sy,sz)
        parts[#parts+1]=self.ctx.ui.raw("Box",{gui=false,x=x,y=y,z=z,
            sizeX=sx,sizeY=sy,sizeZ=sz,color=color,opacity=0.95,
            culling=false,depthTest=false,depthMask=false})
    end
    for _,a in ipairs({-half,half}) do
        for _,b in ipairs({-half,half}) do
            edge(center.x,center.y+a,center.z+b,half*2,thickness,thickness)
            edge(center.x+a,center.y,center.z+b,thickness,half*2,thickness)
            edge(center.x+a,center.y+b,center.z,thickness,thickness,half*2)
        end
    end
    return parts
end

local function scanOrigin(before,after,relative)
    -- Every block offset points to n+0.5, so it reveals the scan origin's
    -- fractional coordinate. Recover its integer part between the eye samples
    -- rather than anchoring the result to a stale pre-call player position.
    local offset=0.5-relative
    local lower=math.ceil(math.min(before,after)-0.05-offset)
    local upper=math.floor(math.max(before,after)+0.05-offset)
    if lower==upper then return lower+offset end
end

function Search:update(now)
    if self.expiresAt and now>=self.expiresAt then
        self:clear()
        if self.active then self.message="Результат устарел; ожидание нового скана" end
    end
    if not self.active or now<self.nextAt then return end
    if not self.scanner and not self:configure() then return end
    local x,y,z=self.ctx.system.getEyePosition()
    x,y,z=finite(x),finite(y),finite(z)
    if not x or not y or not z then
        self.message="Нет позиции игрока" self.nextAt=now+self.interval return
    end
    local ok,blocks,reason=pcall(self.scanner.scanBlocks,self.scanRange)
    self.nextAt=util.epoch()+self.interval
    if not ok or type(blocks)~="table" then
        local errorMessage=tostring(ok and reason or blocks)
        local lower=errorMessage:lower()
        if lower:find("cooldown",1,true) then self.message="Ожидание перезарядки сканера" return end
        if self.scanRange>1 and (lower:find("radius",1,true) or lower:find("fuel",1,true)) then
            self.scanRange=math.max(1,math.floor(self.scanRange/2))
            self.message="Радиус уменьшен до "..self.scanRange.." по ограничению сервера"
            self:clear()
            return
        end
        self:stop("Ошибка сканера: "..errorMessage,true)
        return
    end
    local ax,ay,az=self.ctx.system.getEyePosition()
    ax,ay,az=finite(ax),finite(ay),finite(az)
    for _,block in pairs(blocks) do
        if type(block)=="table" then
            local dx,dy,dz=finite(block.x),finite(block.y),finite(block.z)
            if dx and dy and dz then
                local sx=scanOrigin(x,ax or x,dx)
                local sy=scanOrigin(y,ay or y,dy)
                local sz=scanOrigin(z,az or z,dz)
                if not sx or not sy or not sz then
                    self.message="Поиск продолжается; уточняю новые координаты"
                    return
                end
                x,y,z=sx,sy,sz
                break
            end
        end
    end
    local found,seen={},{}
    local inspected=0
    for _,block in pairs(blocks) do
        if Search.matches(block,self.query) then
            local dx,dy,dz=finite(block.x),finite(block.y),finite(block.z)
            if dx and dy and dz and dx*dx+dy*dy+dz*dz<=(self.scanRange+1)^2 then
                -- AP 0.8.2a returns offsets from the wearer's eye to block
                -- CENTERS. Snap to that grid, including negative coordinates.
                local bx,by,bz=math.floor(x+dx),math.floor(y+dy),math.floor(z+dz)
                local key=("%d:%d:%d"):format(bx,by,bz)
                if not seen[key] then
                    seen[key]=true
                    found[#found+1]={key=key,x=bx+0.5,y=by+0.5,z=bz+0.5,
                        blockX=bx,blockY=by,blockZ=bz,distance=dx*dx+dy*dy+dz*dz}
                end
            end
        end
        inspected=inspected+1
        if inspected%256==0 and self.ctx.tasks then self.ctx.tasks.yield() end
    end
    table.sort(found,function(a,b)
        if a.distance~=b.distance then return a.distance<b.distance end
        return a.key<b.key
    end)
    local visible={}
    for i=1,math.min(#found,self.maxMarkers) do
        local block=found[i]
        visible[block.key]=true
        if not self.markers[block.key] then self.markers[block.key]=self:marker(block) end
        if i%8==0 and self.ctx.tasks then self.ctx.tasks.yield() end
    end
    for key,parts in pairs(self.markers) do
        if not visible[key] then
            for _,part in ipairs(parts) do self.ctx.ui.remove(part) end
            self.markers[key]=nil
        end
    end
    self.total,self.shown=#found,math.min(#found,self.maxMarkers)
    self.nearest=found[1]
    self.bad=false
    self.message=("Найдено: %d · Показано: %d"):format(self.total,self.shown)
    self.expiresAt=util.epoch()+self.interval+1000
end

return Search
