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
local reads = 0
os.epoch = function() return now end
local native = {
    pingSmartChest = function() reads=reads+1 return true, 5 end,
    smartHandPos = function(hand) reads=reads+1 return hand, 0, 0, 0, 0 end,
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
local util = require('m2os.lib.util')
local disk = {}
util.readTable = function(path, fallback) return disk[path] and util.copy(disk[path]) or fallback end
util.writeTable = function(path, value) disk[path]=util.copy(value) return true end
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
keys = {escape=1,r=2,one=3,two=4,three=5,four=6,five=7,tab=8,enter=9}
local texts, menu, services, mode = {}, {}, {}, nil
local notices = {}
local guiWidth, guiHeight = 800, 500
local theme = {background=0x101020,purple=0xA347F5,blue=0x399BFF,
    white=0xFFFFFF,gray=0xB8C2D0,red=0xFF3038,green=0x43E38C,amber=0xFFB84A}
local function object()
    return {setPos=function() end,setColor=function() end,setSizes=function() end,setContent=function() end}
end
local ctx = {
    config={theme=theme},
    ui={clear=function() texts={} end,
        rectangle=object,
        textureRect=object,
        text=function(x,y,value)
            texts[value]={x=x,y=y}
            return object()
        end,
        raw=object},
    system={getSize=function() return guiWidth,guiHeight end,
        getInputMode=function() return mode end,
        setInputMode=function(value) mode=value end,
        getModule=function() return {} end,
        getEyePosition=function() return 0,0,0 end,
        flushOverlay=function() end},
    notify=function(value) notices[#notices+1]=value end,
    menu={add=function(action) menu[action.id]=action end},
    services={provide=function(name, service) services[name]=service end,
        get=function(name) return services[name] end}
}
local app=require('m2os.apps.smart_chestplate')
calls={}
reads=0
app.start(ctx)
app.update(ctx,0)
assert(#calls==0 and mode==nil, 'install/start must not call any native action')
menu['smart_chestplate.panel'].run()
assert(mode=='smart_chestplate')
assert(#calls==0 and reads==0, 'opening must not call native API')
assert(texts['НАГРУДНИК · EXPERIMENTAL'], 'panel must appear in the opening callback')
now=200
app.update(ctx,now)
assert(texts['НАГРУДНИК · EXPERIMENTAL'])
local px,py=400,250
local function click(label, prefixed)
    local target=assert(texts[label],'button not found: '..label)
    local x,y=target.x+2,target.y+2
    if prefixed then app.onEvent(ctx,'player_mouse_move','back',x-px,y-py)
    else app.onEvent(ctx,'player_mouse_move',x-px,y-py) end
    px,py=x,y
    if prefixed then app.onEvent(ctx,'player_mouse_click','back',1)
    else app.onEvent(ctx,'player_mouse_click',1) end
    now=now+300
    app.update(ctx,now)
end
click('Проверить')
assert(reads==2, 'probe and hand position must wait for the explicit Check button')
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

-- Even a missing/throwing chest API cannot prevent the first frame.
local originalProbe=native.pingSmartChest
native.pingSmartChest=function() error('broken equipment API') end
menu['smart_chestplate.panel'].run()
assert(mode=='smart_chestplate' and texts['НАГРУДНИК · EXPERIMENTAL'])
px,py=400,250
click('Проверить')
assert(mode=='smart_chestplate' and texts['НАГРУДНИК · EXPERIMENTAL'])
native.pingSmartChest=originalProbe

-- Resize bursts must keep a bounded first-render deadline.
for tick=1,5 do
    now=now+50
    app.resize(ctx)
    app.update(ctx,now)
end
assert(texts['НАГРУДНИК · EXPERIMENTAL'], 'resize bursts must not postpone drawing forever')
app.stop(ctx)

-- Rendering failures must release input and report the actual draw error.
local originalText=ctx.ui.text
ctx.ui.text=function() error('test rendering failure') end
menu['smart_chestplate.panel'].run()
assert(mode==nil and not services.smart_chestplate.status().open)
assert(notices[#notices]:find('test rendering failure',1,true))
ctx.ui.text=originalText

-- Click geometry must match rendered buttons when the panel is scaled down,
-- and event metadata must not be mistaken for the numeric button/key code.
guiWidth,guiHeight=360,240
menu['smart_chestplate.panel'].run()
px,py=guiWidth/2,guiHeight/2
local beforeReads=reads
click('Проверить',true)
assert(reads==beforeReads+2,'prefixed click must dispatch Check on a scaled panel')
click('Рука 4',true)
assert(services.smart_chestplate.status().hand==4)
click('27',true)
local beforeTransfers=#calls
click('В руку (стак)',true)
assert(#calls==beforeTransfers+1 and calls[#calls].filter.fromSlot==27 and calls[#calls].filter.toSlot==4)
app.resize(ctx)
click('Рука 2',true)
assert(services.smart_chestplate.status().hand==2,'displayed buttons must stay clickable while resize is pending')
app.stop(ctx)
menu['smart_chestplate.panel'].run()
beforeReads=reads
app.onEvent(ctx,'key','back',keys.enter,false)
assert(reads==beforeReads+2,'Enter must activate the initially focused Check button')
app.onEvent(ctx,'key','back',keys.enter,true)
assert(reads==beforeReads+2,'held Enter must not repeat native commands')
app.onEvent(ctx,'key',keys.tab,false)
app.onEvent(ctx,'key',keys.enter,false)
assert(services.smart_chestplate.status().hand==1,'Tab then Enter must select a hand')
app.stop(ctx)
guiWidth,guiHeight=800,500

local Kernel=require('m2os.kernel')
fs={exists=function(path) return path=='/m2os/apps/smart_chestplate.lua' end}
local kernel=setmetatable({config={modules={}},apps={},appOrder={},actions={}},Kernel)
kernel:_loadApps()
assert(kernel.apps.smart_chestplate,'new app must load with preserved module list')

-- Exercise the real radial -> panel handoff with separate UI ownership and
-- a batched overlay, not just isolated app callbacks.
local objects, snapshot, objectId = {}, {}, 0
local overlay = { getGuiSize=function() return 800,500,1 end }
local function create(properties)
    objectId=objectId+1
    local id=objectId
    objects[id]=properties
    return {getId=function() return id end,setPos=function() end,setColor=function() end,
        setOpacity=function() end,setContent=function() end,setSizes=function() end,
        setImageSize=function() end,setPixel=function() end}
end
for _,kind in ipairs({'Rectangle','Texture','Text','Circle'}) do overlay['create'..kind]=create end
overlay.removeObject=function(id) objects[id]=nil end
overlay.update=function()
    snapshot={}
    for _,properties in pairs(objects) do
        if properties.content then snapshot[properties.content]=true end
    end
end
native.modules={overlay=overlay,keyboard={setCaptureMouse=function() end}}
local real=Kernel.new({theme=theme,stateFile='/test-state',modules={}})
local radial=require('m2os.apps.radial_menu')
real:register(app)
real:register(radial)
real:setEnabled(app.id,true)
real:setEnabled(radial.id,true)
reads=0
real:_dispatchEvent({'keyboard_open'})
now=now+200
radial.update(real.apps.radial_menu.context,now)
real:_dispatchEvent({'player_mouse_move',0,-40})
real:_dispatchEvent({'player_mouse_click',1})
assert(real.inputMode=='smart_chestplate')
assert(snapshot['НАГРУДНИК · EXPERIMENTAL'], 'panel must be flushed during real radial handoff')
assert(reads==0, 'real handoff must not wait for equipment API')
real:_dispatchEvent({'keyboard_close'})
overlay.update()
assert(real.inputMode==nil and not snapshot['НАГРУДНИК · EXPERIMENTAL'])

-- Link, source slot, selected hand and last positions survive app restarts.
local saved=assert(disk['/m2os-chestplate.cfg'])
assert(saved.version==1 and saved.linked==true)
app.start(ctx)
assert(services.smart_chestplate.status().hand==saved.hand)
assert(services.smart_chestplate.status().sourceSlot==saved.sourceSlot)
assert(services.smart_chestplate.status().linked)
reads=0
services.smart_chestplate.show()
assert(reads==0,'restoring the panel must still render before querying equipment')
local beforeRestore=#calls
now=now+100
app.update(ctx,now)
assert(reads==2 and services.smart_chestplate.status().online,
    'saved link must reconnect without clicking Check again')
local restored=0
for i=beforeRestore+1,#calls do
    local call=calls[i]
    if call.method=='move' then
        restored=restored+1
        assert(call.position.x==saved.positions[call.hand].x,'saved pose must be applied to the correct hand')
    end
end
local known=0
for _ in pairs(saved.positions) do known=known+1 end
assert(restored==known and restored>0,'all known hand poses must be restored after reconnecting')
services.mob_scan={latest=function() return {entities={},x=0,y=0,z=0,at=now} end}
services.smart_chestplate.setAutoAttack(true)
assert(disk['/m2os-chestplate.cfg'].autoAttack==true)
app.stop(ctx)
app.start(ctx)
assert(services.smart_chestplate.status().autoAttack,'explicitly enabled combat mode must persist')
now=now+300
app.update(ctx,now)
assert(services.smart_chestplate.status().online)
services.smart_chestplate.setAutoAttack(false)
assert(disk['/m2os-chestplate.cfg'].autoAttack==false)
app.stop(ctx)

-- Corrupt nested cache data must not break drawing or reach the native move API.
disk['/m2os-chestplate.cfg']={version=1,linked=true,positions={"invalid",{x=0/0}},receipts={{}}}
app.start(ctx)
beforeRestore=#calls
services.smart_chestplate.show()
now=now+100
app.update(ctx,now)
assert(services.smart_chestplate.status().open and #calls==beforeRestore)
app.stop(ctx)
print('smart chestplate adapter, UI and registration tests: OK')
