-- Run from the repository root: lua tests/smart_chestplate.lua
-- Resolve the installed m2os namespace against this source checkout.
table.insert(package.searchers or package.loaders, 1, function(name)
    if name:match("^m2os%.") then
        local path = name:gsub("^m2os%.", ""):gsub("%.", "/") .. ".lua"
        local chunk = loadfile(path)
        if chunk then return chunk, path end
    end
end)
package.path = './?.lua;./?/init.lua;' .. package.path
local calls, now = {}, 0
os.epoch = function() return now end
local native = {
    pingSmartChest = function() return true, 5 end,
    smartHandPos = function(hand) return hand, 0, 0, 0, 0 end,
    smartHandMove = function(hand, position)
        calls[#calls+1] = {method='move',hand=hand,position=position}
        return true
    end,
    smartChestImportItem = function(filter)
        calls[#calls+1] = {method='load',filter=filter}
        return 12
    end,
    smartChestExportItem = function(filter)
        calls[#calls+1] = {method='unload',filter=filter}
        return 12
    end,
    smartHandAttack = function(hand)
        calls[#calls+1] = {method='attack',hand=hand}
        return true
    end,
    smartHandDig = function(hand)
        calls[#calls+1] = {method='dig',hand=hand}
        return 0.25
    end,
    smartHandUse = function(hand)
        calls[#calls+1] = {method='use',hand=hand}
        return true, 'SUCCESS'
    end,
    smartHandSuckItem = function(hand, count)
        calls[#calls+1] = {method='suck',hand=hand,count=count}
        return 0
    end,
    smartHandDropItem = function(hand, count)
        calls[#calls+1] = {method='drop',hand=hand,count=count}
        return 4
    end,
    smartChestList = function()
        calls[#calls+1] = {method='inventory'}
        return {[12]={name='minecraft:iron_pickaxe',count=1}}
    end
}
local Chest = require('m2os.lib.smart_chestplate')
local chest = Chest.new(native)
local ok, count = chest:probe()
assert(ok and count==5)
assert(not Chest.new({}):probe(), 'missing API must be handled')
local missing = Chest.new({pingSmartChest=function() return false,'SMART_CHEST_NOT_EQUIPPED' end})
local found, reason = missing:probe()
assert(not found and reason:find('не надет',1,true))
assert(not chest:move(6,{x=0,y=0,z=0,pitch=0,yaw=0}))
assert(not chest:move(1,{x=11,y=0,z=0,pitch=0,yaw=0}))
assert(not chest:move(1,{x=0/0,y=0,z=0,pitch=0,yaw=0}))
assert(#calls==0, 'invalid requests must not enter native API')
assert(chest:move(2,{x=1,y=2,z=3,pitch=180,yaw=450}))
assert(calls[1].position.pitch==90 and calls[1].position.yaw==90)
assert(chest:transfer(3,12,true))
assert(calls[2].filter.fromSlot==12 and calls[2].filter.toSlot==3 and calls[2].filter.count==64)
assert(chest:transfer(3,nil,false))
assert(calls[3].filter.fromSlot==3 and calls[3].filter.toSlot==nil)
local empty = Chest.new({smartChestImportItem=function() return 0 end})
assert(not empty:transfer(1,1,true), 'zero moved must not report success')
local broken = Chest.new({smartHandAttack=function() error('Java test failure') end})
assert(not broken:action(1,'attack'), 'native error must not escape adapter')

smartglasses = native
keys = {escape=1,r=2,one=3,two=4,three=5,four=6,five=7}
local texts, menu, services, mode = {}, {}, {}, nil
local theme = {background=0x101020,purple=0xA347F5,blue=0x399BFF,
    white=0xFFFFFF,gray=0xB8C2D0,red=0xFF3038,green=0x43E38C,amber=0xFFB84A}
local function object()
    return {setPos=function() end,setColor=function() end,setSizes=function() end}
end
local ctx = {
    config={theme=theme},
    ui={clear=function() texts={} end,
        rectangle=object,
        text=function(x,y,value)
            texts[value]={x=x,y=y}
            return object()
        end,
        raw=object},
    system={getSize=function() return 800,500 end,
        getInputMode=function() return mode end,
        setInputMode=function(value) mode=value end,
        getModule=function() return {} end,
        flushOverlay=function() end},
    notify=function() end,
    menu={add=function(action) menu[action.id]=action end},
    services={provide=function(name, service) services[name]=service end}
}
local app=require('m2os.apps.smart_chestplate')
calls={}
app.start(ctx)
app.update(ctx,0)
assert(#calls==0 and mode==nil, 'install/start must not call any native action')
menu['smart_chestplate.panel'].run()
assert(mode=='smart_chestplate')
assert(#calls==0, 'opening must not read inventory or mutate hands')
now=200
app.update(ctx,now)
assert(texts['НАГРУДНИК · EXPERIMENTAL'])
local px,py=400,250
local function click(label)
    local target=assert(texts[label],'button not found: '..label)
    local x,y=target.x+2,target.y+2
    app.onEvent(ctx,'player_mouse_move',x-px,y-py)
    px,py=x,y
    app.onEvent(ctx,'player_mouse_click',1)
    now=now+300
    app.update(ctx,now)
end
click('Рука 3')
click('12')
click('В руку (стак)')
assert(#calls==1 and calls[1].method=='load' and calls[1].filter.toSlot==3 and calls[1].filter.fromSlot==12)
click('В инвентарь')
assert(calls[2].method=='unload' and calls[2].filter.fromSlot==3)
click('Читать инв.')
assert(calls[3].method=='inventory', 'source inventory must only read on demand')
click('Удар')
assert(calls[4].method=='attack' and calls[4].hand==3)
for tick=1,10 do now=now+100 app.update(ctx,now) end
assert(#calls==4,'updates must not repeat any action or scan')
click('Копать')
assert(calls[5].method=='dig')
click('Использовать')
assert(calls[6].method=='use')
click('Подобрать')
assert(calls[7].method=='suck' and calls[7].count==64)
click('Выбросить')
assert(calls[8].method=='drop')
local before=#calls
app.resize(ctx)
now=now+200
app.update(ctx,now)
assert(#calls==before,'resize must not issue native operations')
app.onEvent(ctx,'keyboard_close')
assert(mode==nil and not services.smart_chestplate.status().open)
assert(#calls==before,'close must not mutate equipment')
mode='storage'
menu['smart_chestplate.panel'].run()
assert(mode=='storage','opening must respect another app input mode')
mode=nil
menu['smart_chestplate.panel'].run()
now=now+200
app.update(ctx,now)
native.smartChestList=function() error('Java list failed') end
app.onEvent(ctx,'key',keys.r,false)
now=now+300
app.update(ctx,now)
assert(services.smart_chestplate.status().open,'native list errors must not close app')
app.stop(ctx)
assert(mode==nil)

local Kernel=require('m2os.kernel')
fs={exists=function(path) return path=='/m2os/apps/smart_chestplate.lua' end}
local kernel=setmetatable({config={modules={}},apps={},appOrder={},actions={}},Kernel)
kernel:_loadApps()
assert(kernel.apps.smart_chestplate,'new app must load with preserved module list')
print('smart chestplate adapter, UI and registration tests: OK')
