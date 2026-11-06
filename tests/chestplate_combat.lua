-- Run from the repository root: lua tests/chestplate_combat.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match("^m2os%.") then
        local path=name:gsub("^m2os%.",""):gsub("%.","/")..".lua"
        local chunk=loadfile(path)
        if chunk then return chunk,path end
    end
end)
local Combat=require('m2os.lib.chestplate_combat')
local function mob(name,x,extra)
    local e={name=name,uuid=name,health=20,eyeHeight=1.62,x=x,y=-1.62,z=0,aggressive=false}
    for key,value in pairs(extra or {}) do e[key]=value end
    return e
end
local function fixture(entities)
    local sample={entities=entities,x=0,y=0,z=0,at=0}
    local calls={}
    local chest={
        move=function(_,hand,position) calls[#calls+1]={action='move',hand=hand,p=position} return true end,
        action=function(_,hand,action) calls[#calls+1]={action=action,hand=hand} return true end
    }
    local ctx={config={chestplate={attackRange=8}},system={getEyePosition=function() return 0,0,0 end},
        services={get=function() return {latest=function() return sample end} end}}
    return Combat.new(ctx,chest),sample,calls,chest
end

local combat,sample,calls=fixture({mob('minecraft:player',0),mob('minecraft:cow',2),mob('minecraft:zombie',5)})
combat:update(0,true)
assert(#calls==0,'combat must be opt-in')
combat:setEnabled(true)
combat:update(0,false)
assert(#calls==0,'offline equipment must not attack')
combat:update(0,true)
assert(#calls==1 and calls[1].action=='move' and calls[1].hand==1)
assert(math.abs(calls[1].p.yaw+90)<0.01,'hand must aim towards the nearest passive cow')
assert(calls[1].p.x>1 and calls[1].p.x<2)
combat:update(50,true)
assert(#calls==1,'attack must wait for the hand position to settle')
combat:update(100,true)
assert(#calls==2 and calls[2].action=='attack')
sample.at=650
combat:update(650,true)
assert(calls[3].hand==2,'equipped hands must rotate')
combat:setEnabled(false)
combat:update(750,true)
assert(#calls==3,'turning the switch off must cancel a pending attack')

-- Nearby players and armor stands are never selected; targets beside another
-- player are skipped because AP's native raycast cannot filter player hits.
combat,sample,calls=fixture({mob('minecraft:player',0),mob('minecraft:player',2.1,{uuid='other'}),
    mob('minecraft:cow',2),mob('minecraft:armor_stand',1),mob('mod:monster',6)})
combat:setEnabled(true)
combat:update(0,true)
assert(#calls==1 and calls[1].p.x>5,'must skip a mob beside another player')
sample.entities[5].health=0
combat:update(100,true)
assert(#calls==1,'dead/changed target must cancel its pending strike')

combat,sample,calls=fixture({mob('minecraft:player',0),mob('minecraft:player',2,{uuid='other'})})
combat:setEnabled(true)
combat:update(0,true)
assert(#calls==0,'a players-only scan must never cause an attack')

-- All empty hands are detected without treating TOOL_REQUIRED as success.
local chest
combat,sample,calls,chest=fixture({mob('minecraft:zombie',2)})
chest.action=function(_,hand)
    calls[#calls+1]={action='attack',hand=hand}
    return false,'empty','TOOL_REQUIRED'
end
combat:setEnabled(true)
for hand=1,5 do
    local now=(hand-1)*650
    sample.at=now
    combat:update(now,true)
    combat:update(now+100,true)
end
combat:update(3250,true)
assert(not combat.enabled and #calls==10,'five empty hands must stop the mode with a useful error')

-- A native Java error must stop the automatic loop.
combat,sample,calls,chest=fixture({mob('mod:mob',2)})
chest.action=function() return false,'Java test failure','JAVA_EXCEPTION' end
combat:setEnabled(true)
combat:update(0,true)
combat:update(100,true)
assert(not combat.enabled)

-- No tracker: basic scanning must obey the detector's free server radius.
local range,scans
range,scans=0,0
local detector={getConfiguration=function() return {operations={scan_entities={maxFreeRadius=4,defaultCooldown=2000}}} end,
    scanEntities=function(r,detailed)
        assert(detailed==false)
        range=r scans=scans+1
        return {mob('minecraft:cow',2)}
    end}
peripheral={find=function() return detector end}
combat,sample,calls=fixture({})
combat.ctx.services.get=function() return nil end
combat:setEnabled(true)
combat:update(0,true)
combat:update(100,true)
assert(range==4 and scans==1 and #calls==2)
combat:update(650,true)
assert(scans==1,'must not hammer a detector still on cooldown')
print('chestplate automatic combat tests: OK')
