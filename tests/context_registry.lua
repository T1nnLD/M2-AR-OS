-- Run from the repository root: lua tests/context_registry.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match("^m2os%.") then
        local path=name:gsub("^m2os%.",""):gsub("%.","/")..".lua"
        local chunk=loadfile(path)
        if chunk then return chunk,path end
    end
end)
local util=require("m2os.lib.util")
local files,full,failMove={},false,false
local path="/m2os/context_machines.cfg"
util.readTable=function(name,fallback) return files[name] and util.copy(files[name]) or fallback end
util.writeTable=function(name,value)
    files[name]=util.copy(value)
    if full then return false,"out of space" end
    return true
end
fs={exists=function(name) return files[name]~=nil end,
    delete=function(name) files[name]=nil end,
    move=function(from,to)
        if failMove and from==path..".m2tmp" then failMove=false error("rename failed") end
        assert(files[from] and not files[to])
        files[to]=files[from] files[from]=nil
    end}
local function forbidden() error("discovery must not read any inventory/NBT contents") end
local inventory={size=forbidden,list=forbidden}
local devices={['minecraft:chest_0']=inventory,['minecraft:chest_1']=inventory,
    ['minecraft:furnace_0']=inventory,left=inventory,
    block_reader_0={getBlockData=forbidden,getBlockName=forbidden},modem_0={}}
peripheral={getNames=function()
    local names={} for name in pairs(devices) do names[#names+1]=name end return names
end,isPresent=function(name) return devices[name]~=nil end,wrap=function(name) return devices[name] end}
local Registry=require("m2os.lib.context_registry")
local registry=Registry.new({})
local target={name="minecraft:chest",dimension="minecraft:overworld",x=-10,y=64,z=20}
local discovered=registry:discover(target)
assert(#discovered.providers==4,'skip modems and local side aliases')
assert(discovered.providers[1].matches and discovered.providers[2].matches)
assert(not registry:resolve(target),'never guess which of two identical chests is targeted')
local ok,data=registry:bind(target,"minecraft:chest_1")
assert(ok and data.key=="minecraft:overworld:-10:64:20")
assert(registry:resolve(target)=="minecraft:chest_1")
assert(files[path] and not files[path..".bak"] and not files[path..".m2tmp"])
registry=Registry.new({})
assert(registry:resolve(target)=="minecraft:chest_1",'binding must survive a bridge restart')
assert(registry:discover(target).providers[1].name=="minecraft:chest_1")
assert(not registry:bind(target,"left"))
assert(not registry:bind(target,"modem_0"))
assert(not registry:bind({x=1.5,y=64,z=20},"minecraft:chest_0"))
assert(not registry:bind({x=0/0,y=64,z=20},"minecraft:chest_0"))
assert(not registry:bind({dimension="wrong",x=1,y=2,z=3},"minecraft:chest_0"))
local manual=Registry.new({machines={[data.key]="minecraft:chest_0"}})
assert(manual:resolve(target)=="minecraft:chest_0")
assert(not manual:bind(target,"minecraft:chest_1"),'explicit config must take priority')
assert(manual:bind(target,"minecraft:chest_0"))

full=true
local saved=util.copy(files[path])
assert(not registry:bind(target,"minecraft:chest_0"))
assert(registry:resolve(target)=="minecraft:chest_1" and files[path].machines[data.key]==saved.machines[data.key])
assert(not files[path..".m2tmp"],'failed writes must not leave staging copies')
full=false failMove=true
assert(not registry:bind(target,"minecraft:chest_0"))
assert(files[path].machines[data.key]=="minecraft:chest_1",'failed replacement must recover the old file')
files[path..".bak"]=files[path] files[path]=nil
assert(Registry.new({}):resolve(target)=="minecraft:chest_1",'recover an interrupted replacement')
assert(not Registry.new({contextBindingsFile=false}):bind(target,"minecraft:chest_0"))
devices['minecraft:chest_1']=nil
assert(not registry:bind(target,"minecraft:chest_1"),'reject a device detached after discovery')
assert(registry:bind({x=3,y=64,z=5},"block_reader_0"),'Block Readers can be selected explicitly')
print('context registry discovery, persistence and recovery tests: OK')
