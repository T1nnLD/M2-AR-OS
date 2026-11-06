-- Run from the repository root: lua tests/radial_input.lua
table.insert(package.searchers or package.loaders, 1, function(name)
    if name:match("^m2os%.") then
        local path = name:gsub("^m2os%.", ""):gsub("%.", "/") .. ".lua"
        local chunk = loadfile(path)
        if chunk then return chunk, path end
    end
end)

local now = 0
os.epoch = function() return now end
local Kernel = require("m2os.kernel")
local radial = require("m2os.apps.radial_menu")
local kernel = setmetatable({appOrder={},inputMode=nil}, Kernel)
local opened, modalCloses, modalOpen = 0, 0, false
local lines = {}
local keyboard = {setCaptureMouse=function() end}
local function object()
    return {setPos=function() end,setColor=function() end,setContent=function() end,
        setOpacity=function() end,setSizes=function() end}
end
local ctx = {
    config={theme={white=0xFFFFFF,gray=0xAAAAAA,red=0xFF0000,green=0x00FF00,
        purple=0xA347F5,blue=0x399BFF,background=0x101020}},
    ui={clear=function() lines={} end,raw=object,rectangle=object,textureRect=object,
        text=function(_,_,value) lines[value]=true return object() end},
    system={
        getSize=function() return 640,360 end,
        getInputMode=function() return kernel.inputMode end,
        getModule=function() return keyboard end,
        emit=function() end,
        isEnabled=function() return false end
    },
    notify=function(value) error(value) end,
    menu={add=function() end,getAll=function() return {{id="chest",label="CHEST",keepInput=true,
        run=function()
            opened=opened+1
            modalOpen=true
            kernel.inputMode="smart_chestplate"
        end}}
    end}
}
local modal = {enabled=true,failures=0,context={},definition={id="modal",onEvent=function(_,event)
    if event=="keyboard_close" then
        modalCloses=modalCloses+1
        modalOpen=false
        kernel.inputMode=nil
        return true -- Must not prevent radial from seeing lifecycle events.
    end
end}}
local radialOwner={enabled=true,failures=0,definition=radial,context=ctx}
kernel.appOrder={modal,radialOwner}
radial.start(ctx)
local function dispatch(name,...)
    kernel:_dispatchEvent({name,...})
end
local function drawMenu()
    now=now+200
    radial.update(ctx,now)
    assert(lines.SELECT,"radial menu must be drawn on every open")
end

-- Selecting by pointer and then Esc must not open a panel on a closed screen.
dispatch("keyboard_open")
drawMenu()
dispatch("player_mouse_move",0,-40)
dispatch("keyboard_close")
assert(opened==0 and kernel.inputMode==nil and not modalOpen,
    "Esc must cancel without claiming input for a hidden modal")
assert(not lines.SELECT,"consumed close event must still clear radial UI")

-- Clicks queued while GUI geometry is settling cannot execute invisible items.
dispatch("keyboard_open")
dispatch("player_mouse_move",0,-40)
dispatch("player_mouse_click",1)
assert(opened==0)
drawMenu()

-- Reproduce several menu -> chest panel -> Esc -> menu cycles.
for cycle=1,12 do
    if cycle>1 then dispatch("keyboard_open") drawMenu() end
    dispatch("player_mouse_move",0,-40)
    dispatch("player_mouse_click",1)
    assert(opened==cycle and modalOpen and kernel.inputMode=="smart_chestplate")
    dispatch("keyboard_close")
    assert(not modalOpen and kernel.inputMode==nil)
end

-- A dropped close event must recover on the next actual screen opening.
kernel.inputMode="smart_chestplate"
modalOpen=true
local previousCloses=modalCloses
dispatch("keyboard_open")
assert(not modalOpen and kernel.inputMode==nil)
assert(modalCloses==previousCloses+1)
drawMenu()
dispatch("player_mouse_move",0,-40)
dispatch("keyboard_close")
assert(opened==12,"recovery must not execute a previously selected action")

-- Other events still use normal consuming dispatch.
local received=0
kernel.appOrder={
    {enabled=true,definition={id="first",onEvent=function() return true end},context={},failures=0},
    {enabled=true,definition={id="second",onEvent=function() received=received+1 end},context={},failures=0}
}
dispatch("key",1)
assert(received==0,"ordinary key events must not leak to another app")
dispatch("keyboard_close")
assert(received==1,"lifecycle events must reach every app")

-- The active modal receives keys/clicks before an earlier consuming app.
kernel.inputMode="second"
kernel.appOrder[2].definition.onEvent=function() received=received+1 return true end
dispatch("player_mouse_click",1)
assert(received==2,"active modal must receive click before other consumers")
dispatch("key",1)
assert(received==3,"active modal must receive key before other consumers")
dispatch("rednet_message",1,{})
assert(received==3,"non-input events must retain normal priority ordering")
kernel.inputMode=nil

-- Hotkey-only control still uses long press to execute, without Keyboard.
kernel.appOrder={radialOwner}
keyboard=nil
radial.start(ctx)
radial.onEvent(ctx,"glasses_key_pressed",0)
assert(lines.SELECT)
radial.onEvent(ctx,"glasses_key_pressed",650)
assert(opened==13,"hotkey-only long press must still execute selection")
radial.stop(ctx)
print("radial input lifecycle tests: OK")
