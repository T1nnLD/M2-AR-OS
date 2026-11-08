-- Run from the repository root: lua tests/restock.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match('^m2os%.') then
        local path=name:gsub('^m2os%.',''):gsub('%.','/')..'.lua'
        local chunk=loadfile(path) if chunk then return chunk,path end
    end
end)
local util=require('m2os.lib.util')
local now,files,full=0,{},false
os.epoch=function() return now end
util.readTable=function(path,fallback) return files[path] and util.copy(files[path]) or fallback end
util.writeTable=function(path,data) files[path]=util.copy(data) return not full,'out of space' end
fs={exists=function(path) return files[path]~=nil end,delete=function(path) files[path]=nil end,
    move=function(from,to) assert(files[from] and not files[to]) files[to]=files[from] files[from]=nil end}
local Restock=require('m2os.lib.restock')
local function fixture(goal,have,stock)
    now=0 files={} full=false
    local owner='player-a'
    local player={name='minecraft:bread',count=have or 0}
    local source={name='minecraft:bread',count=stock or 1000}
    local imports,reads={},0
    local manager={getOwner=function() reads=reads+1 return owner,'Test Player' end,
        list=function() reads=reads+1 return {[1]=util.copy(player)} end,
        getItemDetail=function() error('no detailed inventory reads allowed') end}
    manager.importItem=function(name,filter)
        assert(name=='minecraft:chest_0' and filter.fromSlot==1)
        local amount=math.min(filter.count,source.count)
        player.count=player.count+amount source.count=source.count-amount
        imports[#imports+1]=util.copy(filter)
        return amount
    end
    local store={name='minecraft:chest_0',peripheral={list=function() reads=reads+1 return {[1]=util.copy(source)} end}}
    local state={manager=manager,inventories={store}}
    local service=Restock.new({restockStartDelayMs=1000})
    if goal then assert(service:set({name='minecraft:bread',count=goal},manager)) end
    local function advance(to)
        while now<to do now=now+500 service:tick(now,state) end
    end
    return service,state,player,source,imports,advance,function(value) owner=value end,function() return reads end
end
local service,state,player,source,imports,advance,owner,reads=fixture()
advance(20000)
assert(reads()==0 and #imports==0,'disabled by default; no rules means no native work')
service,state,player,source,imports,advance=fixture(64,50)
advance(3000)
assert(player.count==64 and #imports==1 and imports[1].count==14)
advance(10000)
assert(#imports==1,'a full target must not create repeat transfers')
player.count=59
advance(18000)
assert(player.count==64 and #imports==2 and imports[2].count==5,'consumption must trigger a fresh deficit only')
local restored=Restock.new({})
assert(restored:status().rules[1].count==64 and restored.rules[1].enabled,'persist rules across bridge restarts')

service,state,player,source,imports,advance=fixture(64,50)
advance(1500) -- owner and first count were read; source search is still pending.
player.count=80
advance(3000)
assert(#imports==0 and player.count==80,'a manual delivery during the cycle must not overfill the minimum')

service,state,player,source,imports,advance=fixture(200,0)
advance(3000)
assert(#imports==1 and imports[1].count==64,'cap each automatic delivery at one stack')
advance(4000)
assert(#imports==1,'do not burst additional orders between configured checks')
advance(25000)
assert(player.count==200 and #imports==4)

service,state,player,source,imports,advance=fixture(64,50,0)
advance(4000)
assert(#imports==0 and service:status().rules[1].message=='Нет предмета на складе')
source.count=100
advance(12000)
assert(player.count==64,'restock must recover when the item becomes available')

service,state,player,source,imports,advance,owner=fixture(64,50)
advance(1500)
owner('player-b')
advance(8000)
assert(#imports==0,'replacing the memory card must not supply another player')

service,state,player,source,imports,advance=fixture(64,50)
local id=service.rules[1].id
advance(1500)
assert(service:edit(id,false,false))
advance(12000)
assert(#imports==0 and not service.rules[1].enabled,'disabling must cancel an already planned delivery')
assert(service:edit(id,true,false))
advance(20000)
assert(player.count==64)
assert(service:edit(id,false,true) and #service.rules==0)
assert(#Restock.new({}).rules==0,'deletion must survive a restart')

service,state,player,source,imports,advance=fixture(64,50)
local attempts=0
state.manager.importItem=function() attempts=attempts+1 return 0 end
advance(20000)
assert(attempts==1,'a full inventory must back off instead of hammering imports')
assert(service:status().rules[1].message:find('Нет места',1,true))

service,state,player,source,imports,advance=fixture(64,50)
state.manager.list=function() error('offline player') end
advance(20000)
assert(#imports==0 and service:status().rules[1].message=='Не удалось прочитать инвентарь')

service,state=fixture(64,50)
full=true
assert(not service:set({name='minecraft:bread',count=128},state.manager))
assert(service.rules[1].count==64 and Restock.new({}).rules[1].count==64,'failed writes must keep the previous rules')
full=false
assert(not service:set({name='minecraft:bread',count=0/0},state.manager))
assert(not service:set({name='minecraft:bread',count=1.5},state.manager))
assert(not service:set({name='bad item',count=64},state.manager))
assert(not service:set({name='minecraft:bread',count=64,id='other-owner'},state.manager))
print('restock persistence, deficits, card ownership, rate limits and recovery tests: OK')
