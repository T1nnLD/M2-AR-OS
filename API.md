# M2OS app API v1

An app is a Lua module which calls `m2os.api.registerApp` and returns its
descriptor. Add the module name to `modules` in `m2os/config.lua`.

```lua
local api = require("m2os.api")

local app = {
    id = "sample",
    name = "Sample App",
    menuLabel = "SAMPLE",
    menuOrder = 50,
    defaultEnabled = true
}

function app.start(ctx)
    app.label = ctx.ui.text(20, 20, "Hello", ctx.config.theme.white, 1, 10)
    ctx.menu.add({
        id = "sample.action",
        label = "SAMPLE ACTION",
        order = 55,
        run = function() ctx.notify("Hello from sample") end
    })
end

function app.update(ctx, nowMs, deltaSeconds)
end

function app.onEvent(ctx, event, ...)
end

function app.resize(ctx, width, height)
end

function app.stop(ctx)
end

api.registerApp(app)
return app
```

Menu actions release Keyboard Module mouse capture after execution. An
interactive app can keep input by setting `keepInput = true`:

```lua
ctx.menu.add({
    id = "sample.window",
    label = "SAMPLE WINDOW",
    keepInput = true,
    run = function() ctx.system.setInputMode("sample") end
})
```

Claiming an input mode during `run` also keeps capture automatically. Clear it
with `ctx.system.setInputMode(nil)` when the interactive window closes.

## Lifecycle

- `start(ctx)` runs when enabled.
- `update(ctx, nowMs, deltaSeconds)` runs on the 50 ms kernel tick.
- `onEvent(ctx, event, ...)` receives raw CC events.
- `resize(ctx, width, height)` runs after the glasses GUI size changes.
- `stop(ctx)` runs before disable/shutdown.

Three errors in a row disable a non-required app. Every overlay object created
through `ctx.ui` belongs to the app and is removed automatically when the app is
disabled. Apps must never call `overlay.clear()`.

## UI

- `ctx.ui.raw(kind, properties)` — any AP overlay object, e.g. `"Box"`.
- `ctx.ui.rectangle(x, y, w, h, color, opacity, z)`
- `ctx.ui.textureRect(...)` — solid texture safe behind a PNG.
- `ctx.ui.line(x1, y1, x2, y2, color, opacity, width, z)`
- `ctx.ui.text(x, y, text, color, size, z, shadow)`
- `ctx.ui.remove(object)`
- `ctx.ui.clear()` — only this app's objects.

## System and services

- `ctx.system.getSize()`
- `ctx.system.getEyePosition()`
- `ctx.system.getModule(name)`
- `ctx.system.isEnabled(appId)` / `enable(appId, boolean)`
- `ctx.system.emit(event, ...)`
- `ctx.services.provide(name, methods)`
- `ctx.services.get(name)`
- `ctx.notify(message, color)`

Services are normal Lua tables and calls are local. They disappear automatically
when their owner app stops.

## Storage service

```lua
local storage = ctx.services.get("storage")

storage.stock("iron", function(ok, data, err)
    -- data.items
end)

storage.withdraw("minecraft:iron_ingot", 16, callback)
storage.deposit("minecraft:cobblestone", 64, callback)
storage.craft("minecraft:precision_mechanism", 1, callback)
storage.inspect({
    dimension = "minecraft:overworld", x = 10, y = 64, z = -20
}, callback)
```

All bridge calls are asynchronous; callbacks receive `(ok, data, error)`.

## Context providers

An app can add local information for a target before the bridge is queried:

```lua
local context = ctx.services.get("context")
context.addProvider("sample", function(target)
    if target.name == "example:block" then
        return { message = "Custom block information" }
    end
end)
```
