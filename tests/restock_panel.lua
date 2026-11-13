-- Run from the repository root: lua tests/restock_panel.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match('^m2os%.') then
        local path=name:gsub('^m2os%.',''):gsub('%.','/')..'.lua'
        local chunk=loadfile(path) if chunk then return chunk,path end
    end
end)
local util=require('m2os.lib.util')
local Panel=require('m2os.lib.restock_panel')
local mode,now,requests=nil,0,{}
os.epoch=function() return now end
keys={escape=1,enter=2,up=3,down=4,backspace=5,leftCtrl=6,rightCtrl=7,leftShift=8,rightShift=9}
local created,removed,changes=0,0,0
local function object()
    created=created+1
    local item={removed=false,setPos=function() end}
    for _,method in ipairs({'setContent','setColor','setOpacity'}) do
        item[method]=function() assert(not item.removed) changes=changes+1 end
    end
    return item
end
local ctx={config={theme={white=1,gray=2,purple=3,background=4,red=5}},
    ui={clear=function() end,rectangle=object,textureRect=object,text=object,raw=object,
        remove=function(item) assert(not item.removed) item.removed=true removed=removed+1 end},
    notify=function(message) error(message) end,
    system={getSize=function() return 500,330 end,getInputMode=function() return mode end,
        setInputMode=function(value) mode=value end,flushOverlay=function() end}}
local function request(operation,payload,callback)
    requests[#requests+1]={operation=operation,payload=payload,callback=callback}
end
local panel=Panel.new(ctx,request)
local saved={rules={{id='owner|minecraft:torch',name='minecraft:torch',label='Факел',count=32,enabled=true,message='В наличии'}}}
panel:show({name='minecraft:bread',displayName='Хлеб'})
assert(mode=='restock' and requests[1].operation=='restock_status')
assert(created==0,'wait for the initial window dimensions before drawing')
requests[1].callback(true,util.copy(saved))
assert(panel.selected==2 and panel.rules[2].name=='minecraft:bread')
now=180 panel:frame(now)
local initialObjects=created
local initialCursor=panel.window.cursor
panel.focus=true
panel.count=''
panel:onEvent('char','4') panel:onEvent('char','8')
assert(panel.count=='48')
now=2000 panel:update(now)
requests[#requests].callback(true,util.copy(saved))
assert(panel.count=='48' and panel.focus and panel.selected==2,'polling must not reset typed quantities or focus')
assert(created==initialObjects and removed==0 and panel.window.cursor==initialCursor,
    'typing and polling must retain all window objects and the cursor')
local idleChanges=changes
panel:frame(now)
assert(changes==idleChanges,'unchanged contents must not send redundant property updates')
panel:onEvent('key',keys.enter,false)
local write=requests[#requests]
assert(write.operation=='restock_set' and write.payload.count==48 and write.payload.name=='minecraft:bread')
panel:onEvent('key',keys.enter,false)
assert(requests[#requests]==write,'rapid Enter must not submit duplicate mutations')
local updated=util.copy(saved)
updated.rules[2]={id='owner|minecraft:bread',name='minecraft:bread',label='Хлеб',count=48,enabled=true}
write.callback(true,updated)
assert(panel.rules[panel.selected].id=='owner|minecraft:bread')
panel:change(false)
assert(requests[#requests].operation=='restock_toggle' and requests[#requests].payload.enabled==false)
requests[#requests].callback(false,nil,'out of space')
assert(panel.bad and panel.rules[panel.selected].enabled,'failed saves must not fake a disabled rule')
panel:change(true)
assert(requests[#requests].operation=='restock_remove')
requests[#requests].callback(true,util.copy(saved))
assert(#panel.rules==1)
assert(created==initialObjects,'changing/deleting rules must not rebuild the window')
panel:onEvent('key',keys.escape,false)
assert(not panel.open and mode==nil)

-- Ignore a reply belonging to an earlier modal session.
panel:show()
local stale=requests[#requests]
panel:close()
panel:show()
stale.callback(true,updated)
assert(#panel.rules==0)
requests[#requests].callback(true,util.copy(saved))
now=now+200 panel:frame(now)
local function hit(id)
    for _,button in ipairs(panel.window.hits) do if button.id==id then return button end end
end
local plus=hit('plus')
panel:onEvent('player_mouse_move','back',plus.x+2-panel.window.px,plus.y+2-panel.window.py)
panel:onEvent('key',keys.leftCtrl,false)
panel:onEvent('player_mouse_click','back',1)
assert(panel.count=='42','Ctrl changes the quantity by ten')
panel:onEvent('key_up',keys.leftCtrl)
panel:onEvent('key',keys.leftShift,false)
panel:onEvent('player_mouse_click',1)
assert(panel.count=='106','Shift changes the quantity by a stack')
panel:onEvent('keyboard_close')
assert(mode==nil)

panel:show()
requests[#requests].callback(false,nil,'unknown operation restock_status')
assert(panel.unsupported and panel.message:find('Обнови',1,true))
local before=#requests
now=now+5000 panel:update(now)
assert(#requests==before,'do not spam unsupported operations on an old bridge')
panel:bridgeReady() panel:update(now)
assert(#requests==before+1,'retry after discovering an upgraded bridge')
requests[#requests].callback(true,util.copy(saved))
panel:close()
print('restock panel controls, persistence feedback and asynchronous polling tests: OK')
