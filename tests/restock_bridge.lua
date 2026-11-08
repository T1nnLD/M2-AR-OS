-- Run from the repository root: lua tests/restock_bridge.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match('^m2os%.') then
        local path=name:gsub('^m2os%.',''):gsub('%.','/')..'.lua'
        local chunk=loadfile(path) if chunk then return chunk,path end
    end
end)
local util=require('m2os.lib.util')
local now,files,events,replies,imports=0,{},{},{},{}
os.epoch=function() return now end
os.getComputerID=function() return 9 end
local timer=0
os.startTimer=function() timer=timer+1 return timer end
os.cancelTimer=function() end
os.pullEventRaw=function()
    local event=assert(table.remove(events,1),'event stream exhausted')
    now=event.at or now
    return table.unpack(event)
end
util.findWirelessModem=function() return 'modem_0' end
util.readTable=function(path,fallback) return files[path] and util.copy(files[path]) or fallback end
util.writeTable=function(path,data) files[path]=util.copy(data) return true end
fs={exists=function(path) return files[path]~=nil end,delete=function(path) files[path]=nil end,
    move=function(from,to) assert(files[from] and not files[to]) files[to]=files[from] files[from]=nil end}
local player={name='minecraft:bread',count=50}
local stock={name='minecraft:bread',count=100}
local manager={getOwner=function() return 'owner-uuid','Test' end,list=function() return {[1]=util.copy(player)} end,
    exportItem=function() error('restock must never deposit or remove surplus') end}
manager.importItem=function(name,filter)
    assert(name=='minecraft:chest_0')
    local moved=math.min(stock.count,filter.count)
    imports[#imports+1]=filter.count
    player.count=player.count+moved stock.count=stock.count-moved
    return moved
end
local devices={inventory_manager_0=manager,['minecraft:chest_0']={list=function() return {[1]=util.copy(stock)} end,size=function() return 27 end}}
peripheral={getNames=function() return {'inventory_manager_0','minecraft:chest_0'} end,
    wrap=function(name) return devices[name] end,find=function() return nil end,
    getType=function(name) return name=='inventory_manager_0' and 'inventory_manager' or 'inventory' end}
local open=false
rednet={isOpen=function() return open end,open=function() open=true end,close=function() open=false end,
    send=function(_,message) replies[message.id]=message end}
term={clear=function() end,setCursorPos=function() end}
parallel={waitForAll=function(requestLoop) requestLoop() end}
local function request(id,operation,payload,at,sender)
    events[#events+1]={'rednet_message',sender or 42,{kind='request',id=id,key='secret',operation=operation,payload=payload},'test-restock',at=at}
end
request('set','restock_set',{name='minecraft:bread',count=64},0)
request('denied','restock_set',{name='minecraft:bread',count=999},0,43)
events[#events+1]={'timer',999,at=11000} -- The original service timer was lost during a native call.
events[#events+1]={'timer',999,at=11500}
request('manual','withdraw',{name='minecraft:bread',count=2},11600)
events[#events+1]={'timer',999,at=12000}
request('status','restock_status',{},12500)
request('off','restock_toggle',{id='owner-uuid|minecraft:bread',enabled=false},13000)
request('remove','restock_remove',{id='owner-uuid|minecraft:bread'},13500)
events[#events+1]={'terminate'}
local output=print print=function() end
require('m2os.server').run({protocol='test-restock',sharedKey='secret',trustedIds={42},enableItemDetails=false})
print=output
assert(replies.set.ok and not replies.denied.ok,'rules must respect the bridge trust settings')
assert(replies.manual.ok and imports[1]==2)
assert(#imports==2 and imports[2]==12 and player.count==64,'manual delivery must reduce the automatic deficit')
assert(replies.status.data.rules[1].current==64)
assert(replies.off.ok and not replies.off.data.rules[1].enabled)
assert(replies.remove.ok and #files['/m2os/restock.cfg'].rules==0)
assert(not open)
print('restock bridge authorization, manual-order interaction and timer recovery tests: OK')
