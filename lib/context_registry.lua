-- Generic inventory and Block Reader APIs do not expose reliable world
-- coordinates. Discover names only, then persist an explicitly selected pair.
local util = require("m2os.lib.util")
local Registry = {}
Registry.__index = Registry
local SIDES = {left=true,right=true,front=true,back=true,top=true,bottom=true}

local function targetKey(target)
    if type(target) ~= "table" then return nil,"Не указан блок" end
    local dimension=target.dimension or "minecraft:overworld"
    if type(dimension)~="string" or not dimension:match("^[%w_.-]+:[%w_./-]+$") then
        return nil,"Неверное измерение"
    end
    local coords={}
    for _,axis in ipairs({"x","y","z"}) do
        local value=tonumber(target[axis])
        if not value or value~=value or math.abs(value)>30000000 or value%1~=0 then
            return nil,"Неверные координаты блока"
        end
        coords[#coords+1]=value
    end
    return ("%s:%d:%d:%d"):format(dimension,coords[1],coords[2],coords[3])
end

local function provider(name)
    if type(name)~="string" or SIDES[name] or not peripheral.isPresent(name) then return end
    local object=peripheral.wrap(name)
    if not object then return end
    if type(object.getBlockData)=="function" and type(object.getBlockName)=="function" then
        return {name=name,kind="reader"}
    end
    if type(object.list)=="function" and type(object.size)=="function" then
        return {name=name,kind="inventory"}
    end
end

function Registry.new(config)
    local path=config.contextBindingsFile
    if path==nil then path="/m2os/context_machines.cfg" end
    local entries={}
    if path then
        -- Recover an interrupted replacement before reading the small registry.
        if fs.exists(path..".bak") and not fs.exists(path) then fs.move(path..".bak",path) end
        local ok,saved=pcall(util.readTable,path,{})
        if ok and type(saved)=="table" and saved.version==1 and type(saved.machines)=="table" then
            for key,name in pairs(saved.machines) do
                if type(key)=="string" and type(name)=="string" and not SIDES[name] then entries[key]=name end
            end
        end
    end
    return setmetatable({config=config,path=path,entries=entries},Registry)
end

function Registry:resolve(target)
    local key,err=targetKey(target)
    if not key then return nil,nil,err end
    return (self.config.machines or {})[key] or self.entries[key],key
end

function Registry:discover(target)
    local key=targetKey(target)
    local current=key and ((self.config.machines or {})[key] or self.entries[key])
    local items={}
    for _,name in ipairs(peripheral.getNames()) do
        local item=provider(name)
        if item then
            item.current=name==current
            item.matches=type(target)=="table" and item.kind=="inventory"
                and name:gsub("_%d+$","")==target.name or false
            items[#items+1]=item
        end
    end
    table.sort(items,function(a,b)
        if a.current~=b.current then return a.current end
        if a.matches~=b.matches then return a.matches end
        return a.name<b.name
    end)
    return {providers=items,provider=current,key=key}
end

function Registry:bind(target,name)
    local key,err=targetKey(target)
    if not key then return false,err end
    if not provider(name) then return false,"Устройство отключено или не поддерживается; обнови список" end
    local manual=(self.config.machines or {})[key]
    if manual and manual~=name then return false,"Для блока задана ручная запись machines; сначала измени её" end
    if manual then return true,{provider=manual,key=key,source="config"} end
    if not self.path then return false,"Сохранение привязок отключено в настройках моста" end
    local nextEntries=util.copy(self.entries)
    nextEntries[key]=name
    local temp,backup=self.path..".m2tmp",self.path..".bak"
    local ok,written,reason=pcall(util.writeTable,temp,{version=1,machines=nextEntries})
    if not ok or not written then
        if fs.exists(temp) then pcall(fs.delete,temp) end
        return false,"Не удалось сохранить привязку: " .. tostring(ok and reason or written)
    end
    local replaced,errorMessage=pcall(function()
        if fs.exists(backup) then fs.delete(backup) end
        if fs.exists(self.path) then fs.move(self.path,backup) end
        fs.move(temp,self.path)
    end)
    if not replaced then
        if fs.exists(backup) and not fs.exists(self.path) then pcall(fs.move,backup,self.path) end
        if fs.exists(temp) then pcall(fs.delete,temp) end
        return false,"Не удалось заменить файл привязок: " .. tostring(errorMessage)
    end
    self.entries=nextEntries
    if fs.exists(backup) then pcall(fs.delete,backup) end
    return true,{provider=name,key=key,source="saved"}
end

return Registry
