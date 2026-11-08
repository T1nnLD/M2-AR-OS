-- Run from the repository root: lua tests/restock_storage.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match('^m2os%.') then
        local path=name:gsub('^m2os%.',''):gsub('%.','/')..'.lua'
        local chunk=loadfile(path) if chunk then return chunk,path end
    end
end)
local util=require('m2os.lib.util')
local requests,services,actions,mode={},{},{},nil
os.epoch=function() return 0 end
os.getComputerID=function() return 12 end
util.findWirelessModem=function() return 'modem_0' end
rednet={isOpen=function() return true end,broadcast=function() end,
    send=function(_,message) requests[#requests+1]=message end}
keys={f=1,k=2,i=3,enter=4,escape=5,up=6,down=7,backspace=8,
    leftCtrl=9,rightCtrl=10,leftShift=11,rightShift=12}
local function object()
    return setmetatable({getId=function() return 1 end},{__index=function() return function() end end})
end
local theme={white=1,gray=2,purple=3,background=4,red=5,green=6,blue=7,amber=8,yellow=9}
local ctx={config={theme=theme,storage={protocol='test',sharedKey='secret',gridColumns=8,gridRows=4}},
    ui={clear=function() end,rectangle=object,textureRect=object,text=object,raw=object},
    notify=function() end,
    system={getSize=function() return 500,400 end,getModule=function() return nil end,
        getInputMode=function() return mode end,setInputMode=function(value) mode=value end,flushOverlay=function() end},
    services={provide=function(name,service) services[name]=service end},
    menu={add=function(action) actions[action.id]=action end}}
local app=require('m2os.apps.storage')
local function reply(data)
    local request=requests[#requests]
    app.onEvent(ctx,'rednet_message',42,{kind='response',key='secret',id=request.id,ok=true,data=data},'test')
end
app.start(ctx)
app.onEvent(ctx,'rednet_message',42,{kind='hello',key='secret',version=12},'test')
services.storage.show()
local stock={items={{name='minecraft:bread',displayName='Хлеб',count=100}}}
reply(stock)
assert(mode=='storage')
app.onEvent(ctx,'key',keys.f)
app.onEvent(ctx,'key',keys.k)
app.onEvent(ctx,'char','k')
assert(mode=='storage','K in an active search must remain a typed character')
app.onEvent(ctx,'key',keys.enter)
reply(stock)
app.onEvent(ctx,'key',keys.k)
assert(mode=='restock' and requests[#requests].operation=='restock_status')
reply({rules={}})
app.onEvent(ctx,'key',keys.enter)
assert(requests[#requests].operation=='restock_set' and requests[#requests].payload.name=='minecraft:bread')
assert(requests[#requests].payload.count==64)
reply({rules={{id='owner|minecraft:bread',name='minecraft:bread',label='Хлеб',count=64,enabled=true}}})
app.onEvent(ctx,'key',keys.escape)
assert(mode==nil,'closing the restock panel must release input')
actions['storage.restock'].run()
assert(mode=='restock' and requests[#requests].operation=='restock_status')
reply({rules={}})
app.resize(ctx)
app.onEvent(ctx,'keyboard_close')
assert(mode==nil)
app.stop(ctx)
print('storage K shortcut, search input, restock replies and radial action tests: OK')
