-- Run from the repository root: lua tests/block_search.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match('^m2os%.') then
        local path=name:gsub('^m2os%.',''):gsub('%.','/')..'.lua'
        local chunk=loadfile(path) if chunk then return chunk,path end
    end
end)
local Search=require('m2os.lib.block_search')
local now=0 os.epoch=function() return now end
assert(Search.normalize(' Diamond_Ore ')=='minecraft:diamond_ore')
assert(Search.normalize('#C:ORES/DIAMOND')=='#c:ores/diamond')
assert(not Search.normalize('алмазная руда'))
assert(not Search.normalize(''))
assert(Search.matches({tags={'c:ores/diamond'}},'#c:ores/diamond'))
assert(Search.matches({tags={['c:ores/diamond']=true}},'#c:ores/diamond'))
local function fixture(config)
    now=0
    local calls,objects,removed={},{},{}
    local position={10.25,65.62,-20.75}
    local blocks={}
    local scanner={getConfiguration=function() return config or {operations={scan_blocks={maxFreeRadius=4,defaultCooldown=8000}}} end}
    scanner.scanBlocks=function(radius) calls[#calls+1]=radius return blocks end
    peripheral={find=function(kind) if kind=='geo_scanner' then return scanner,'back' end end}
    local ctx={config={theme={yellow=0xFFD54A},tracker={range=16,intervalMs=100},blockSearch={maxMarkers=2}},
        system={getEyePosition=function() return table.unpack(position) end},
        ui={raw=function(kind,properties)
            assert(kind=='Box' and properties.depthTest==false)
            local object={properties=properties}
            objects[#objects+1]=object
            return object
        end,remove=function(object) removed[object]=true end}}
    return Search.new(ctx),calls,objects,removed,position,blocks,scanner,ctx
end
local search,calls,objects,removed,position,blocks,scanner,ctx=fixture()
local function block(name,x,y,z) return {name=name,x=x-position[1],y=y-position[2],z=z-position[3]} end
blocks[1]=block('minecraft:diamond_ore',12.5,64.5,-20.5)
blocks[2]=block('minecraft:diamond_ore',9.5,64.5,-20.5)
blocks[3]=blocks[2] -- duplicate entries must not create duplicate boxes.
blocks[4]=block('minecraft:stone',10.5,65.5,-20.5)
assert(search:start('diamond_ore',16))
search:update(0)
assert(#calls==0,'start must schedule native calls for a later update')
now=100 search:update(now)
assert(calls[1]==4 and search.interval==8050,'respect the free radius and server cooldown like the entity tracker')
assert(search.total==2 and search.shown==2 and #objects==24)
assert(search.nearest.blockX==9 and search.nearest.blockY==64 and search.nearest.blockZ==-21)
local edge=search.markers['9:64:-21'][1].properties
assert(math.abs(edge.x-9.5)<0.00001 and math.abs(edge.y-63.99)<0.00001,
    'offsets point to block centers, not corners or player feet')
now=1000 search:update(now)
assert(#calls==1)
now=8200 search:update(now)
assert(#calls==2 and #objects==24,'reuse unchanged world marker objects')
blocks[1]=nil blocks[2]=nil blocks[3]=nil
now=16300 search:update(now)
assert(search.total==0 and search.shown==0 and next(search.markers)==nil)
for _,object in ipairs(objects) do assert(removed[object]) end

search,calls,objects,removed,position,blocks,scanner,ctx=fixture({operations={scan_blocks={maxFreeRadius=8}}})
position[1]=-0.2
blocks[1]={name='minecraft:diamond_ore',x=-2.3,y=64.5-position[2],z=0.25}
assert(search:start('diamond_ore',8)) now=100 search:update(now)
assert(search.nearest.blockX==-3,'negative coordinates must floor to the block, never truncate towards zero')

search,calls,objects,removed,position,blocks,scanner,ctx=fixture({operations={scan_blocks={maxFreeRadius=8}}})
for i=1,4 do blocks[i]={name='minecraft:stone',x=i+0.25,y=-0.12,z=0.25} end
assert(search:start('stone',8)) now=100 search:update(now)
assert(search.total==4 and search.shown==2 and #objects==24,'bound the number of overlay objects')
search:stop()
assert(not search.active and next(search.markers)==nil)

search,calls,objects,removed,position,blocks,scanner,ctx=fixture()
scanner.scanBlocks=function() error('Java test failure') end
search:start('stone',8) now=100 search:update(now)
assert(not search.active and search.bad,'a Java failure must stop automatic retries')

search,calls,objects,removed,position,blocks,scanner,ctx=fixture({operations={scan_blocks={maxFreeRadius=0}}})
search:start('stone',8) now=100 search:update(now)
assert(not search.active and #calls==0,'never attempt paid scans when the glasses have no free radius')

search,calls,objects,removed,position,blocks,scanner,ctx=fixture()
scanner.scanBlocks=function() calls[#calls+1]=1 return nil,'Operation is on cooldown' end
search:start('stone',8) now=100 search:update(now)
now=1000 search:update(now)
assert(search.active and #calls==1,'cooldown errors must wait, not spin')

search,calls,objects,removed,position,blocks,scanner,ctx=fixture()
blocks[1]={name='minecraft:stone',x=0.25,y=-0.12,z=0.25}
scanner.scanBlocks=function() position[1]=position[1]+2 return blocks end
search:start('stone',8) now=100 search:update(now)
assert(search.total==0 and #objects==0,'reject a scan if fast movement makes its origin ambiguous')

search,calls=fixture()
peripheral.find=function() return nil end
search:start('stone',8) now=100 search:update(now)
assert(not search.active and #calls==0)

search,calls,objects,removed,position,blocks,scanner,ctx=fixture({operations={}})
scanner.scanBlocks=function(radius) calls[#calls+1]=radius return nil,'not enough fuel' end
search:start('stone',8)
for _,time in ipairs({100,5100,10100,15100}) do now=time search:update(now) end
assert(calls[1]==8 and calls[2]==4 and calls[3]==2 and calls[4]==1 and not search.active,
    'older configurations must reduce refused radii and eventually stop')

-- Reconcile a live scan origin while walking; a >0.5-block change during a
-- native call must not require the player to stop or offset the boxes.
search,calls,objects,removed,position,blocks,scanner,ctx=fixture({operations={scan_blocks={maxFreeRadius=12,defaultCooldown=150}}})
ctx.config.tracker={range=32,intervalMs=250}
ctx.config.blockSearch.range=1 ctx.config.blockSearch.intervalMs=99999
scanner.scanBlocks=function(radius)
    calls[#calls+1]=radius
    local centerX=position[1]+0.6
    local bx=math.floor(centerX)+2
    local result={{name='minecraft:stone',x=bx+0.5-centerX,y=64.5-position[2],z=-20.5-position[3]}}
    position[1]=position[1]+0.7
    return result
end
search:start('stone',1) -- obsolete explicit distances must not override shared settings.
now=100 search:update(now)
assert(calls[1]==12 and search.radius==32 and search.interval==250)
assert(search.active and search.total==1 and search.nearest.blockX==12)
now=349 search:update(now) assert(#calls==1)
now=350 search:update(now)
assert(#calls==2 and search.active and search.nearest.blockX==13,'continue finding new blocks while the wearer walks')
print('geo block search filtering, world alignment, caps, cooldown and error tests: OK')
