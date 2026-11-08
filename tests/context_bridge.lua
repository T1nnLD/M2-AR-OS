-- Run from the repository root: lua tests/context_bridge.lua
table.insert(package.searchers or package.loaders,1,function(name)
    if name:match("^m2os%.") then
        local path=name:gsub("^m2os%.",""):gsub("%.","/")..".lua"
        local chunk=loadfile(path)
        if chunk then return chunk,path end
    end
end)
local util=require('m2os.lib.util')
local files,replies,events,reads={},{},{},0
util.findWirelessModem=function() return 'modem_0',{} end
util.readTable=function(path,fallback) return files[path] and util.copy(files[path]) or fallback end
util.writeTable=function(path,value) files[path]=util.copy(value) return true end
fs={exists=function(path) return files[path]~=nil end,delete=function(path) files[path]=nil end,
    move=function(from,to) assert(files[from] and not files[to]) files[to]=files[from] files[from]=nil end}
local reader={getBlockName=function() error('no block-name probe expected') end,
    getBlockData=function() reads=reads+1 return {CookTime=50,CookTimeTotal=100} end}
peripheral={getNames=function() return {'block_reader_0'} end,
    wrap=function(name) return name=='block_reader_0' and reader or nil end,
    isPresent=function(name) return name=='block_reader_0' end,
    getType=function() return 'block_reader' end,find=function() return nil end}
local open=false
rednet={isOpen=function() return open end,open=function() open=true end,close=function() open=false end,
    send=function(recipient,message,protocol)
        assert(protocol=='test-context')
        replies[message.id]={recipient=recipient,message=message,reads=reads}
    end}
term={clear=function() end,setCursorPos=function() end}
os.epoch=function() return 0 end
os.getComputerID=function() return 9 end
os.startTimer=function() return 1 end
os.pullEventRaw=function()
    local event=table.remove(events,1)
    assert(event,'request loop must eventually terminate')
    return table.unpack(event)
end
-- Exercise the real bridge request loop with scripted network events; the
-- unrelated metadata indexer stays idle with detailed reads disabled.
parallel={waitForAll=function(requestLoop) requestLoop() end}
local target={name='minecraft:furnace',dimension='minecraft:overworld',x=12,y=64,z=-6}
local function request(id,operation,payload,sender,key)
    events[#events+1]={'rednet_message',sender or 42,{kind='request',id=id,key=key or 'secret',
        operation=operation,payload=payload},'test-context'}
end
local binding=util.copy(target) binding.provider='block_reader_0'
request('find','context_discover',target)
request('bad-key','context_bind',binding,42,'wrong')
request('untrusted','context_bind',binding,43)
request('bind','context_bind',binding)
request('inspect','inspect',target)
request('current','context_discover',target)
request('invalid','context_bind',{x=1.5,y=64,z=0,provider='block_reader_0'})
events[#events+1]={'terminate'}
local output=print
print=function() end
local Server=require('m2os.server')
Server.run({protocol='test-context',sharedKey='secret',trustedIds={42},enableItemDetails=false})
print=output
assert(not open,'bridge must close its modem on shutdown')
assert(replies.find.message.ok and #replies.find.message.data.providers==1 and replies.find.reads==0)
assert(not replies['bad-key'],'ignore an invalid shared key')
assert(not replies.untrusted.message.ok,'context registration must obey trustedIds')
assert(replies.bind.message.ok and replies.bind.reads==0,'binding must not decode block NBT')
assert(files['/m2os/context_machines.cfg'].machines['minecraft:overworld:12:64:-6']=='block_reader_0')
assert(replies.inspect.message.data.progress==0.5 and reads==1,'inspection must resolve the saved provider')
assert(replies.current.message.data.providers[1].current)
assert(not replies.invalid.message.ok)
print('context bridge discovery, authorization, binding and inspection tests: OK')
