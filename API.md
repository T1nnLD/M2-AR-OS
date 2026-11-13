# M2OS app API v1 — asynchronous runtime

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
    -- Fast GUI updates only; do not wait for scanners here.
end

function app.poll(ctx, nowMs, deltaSeconds)
    -- Sensor I/O. Independent cancellable worker for this app.
end

function app.logic(ctx, nowMs, deltaSeconds)
    -- Background deadlines, networking and other non-GUI logic.
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

Menu actions close the radial overlay after execution. Advanced Peripherals
0.8.2a cannot close its Keyboard Screen from Lua, so a non-interactive action
shows an `Esc` prompt when the Keyboard module was used. An interactive app can
keep that input screen by setting `keepInput = true`:

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

- `start(ctx)` runs asynchronously when enabled. GUI/events/polling for this app
  begin only after it completes; `setEnabled` acknowledges scheduling, not completion.
- `update(ctx, nowMs, deltaSeconds)` runs on the 50 ms GUI tick. Keep it nonblocking.
- `poll(ctx, nowMs, deltaSeconds)` runs in a separate sensor task per app, with
  `pollIntervalMs` (minimum/default 50) between completed calls.
- `logic(ctx, nowMs, deltaSeconds)` runs on that app's backend worker, with
  `logicIntervalMs` (minimum/default 50). Backend events share this worker.
- `onEvent(ctx, event, ...)` receives input on the GUI task; returning true
  consumes it. The active input owner is tried first. Keyboard open/close is
  broadcast. Non-input events are broadcast to per-app backend mailboxes;
  returning true there does not prevent another app from receiving its copy.
  Internal scheduler timers/wakes and native `task_complete` are not passed to
  these callbacks; native waits inside scheduled functions still receive them.
- `resize(ctx, width, height)` runs after the glasses GUI size changes.
- `stop(ctx)` performs nonblocking cleanup after owned tasks/timers have been cancelled.

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

## Shared windows

Create a retained modal with `ctx.ui.window`. The kernel handles its GUI frame
updates, settled resizes and cleanup automatically:

```lua
local window
local message = "Готово"
function app.start(ctx)
    window = ctx.ui.window({
        width = 320, height = 160,
        build = function(w)
            w:text("status", 12, 15, "")
            w:button("action", 12, 45, 140, 22, "Обновить", function()
                message = "Нажато"
            end)
        end,
        update = function(w)
            w:set("status", "setContent", message)
        end
    })
    ctx.menu.add({id="sample.open", label="ОКНО", run=function() window:show() end})
end
function app.onEvent(ctx, event, ...)
    return window:onEvent(event, ...)
end
```

The window claims its app's input mode by default; `mode` can override the name.
`onClose(window)` can reset application state. Its initial display waits 180ms
for Keyboard screen geometry. A resize burst is coalesced with a 500ms maximum
wait; the old layout stays clickable until replacement. The pointer retains its
position relative to the panel. Ordinary `draw()` calls update existing objects
without clearing, re-centering or recreating the cursor.

Coordinates passed to `text`, `rectangle` and `button` are local to the window.
`set(id, method, value)` caches single-value setters such as `setContent`,
`setColor` and `setOpacity`. Button objects use IDs `id.label` and
`id.background`; `enableButton(id, boolean)` controls hit testing. `draw()`
publishes changed contents immediately; the kernel performs periodic updates.
`close()` removes only the window's own objects, leaving its app's world markers
alone. Use unique widget IDs within a window and keep build/update callbacks
nonblocking; sensor work still belongs in `poll` or an owned background task.

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
when their owner app stops. During asynchronous startup a service can be absent;
consumers should handle that until its owner finishes initialization.

## Owned background tasks

```lua
ctx.tasks.spawn("read", function(ctx)
    local data = peripheral.call("back", "someMethod") -- may yield
    -- Validate results, then publish a complete result to app state.
end)
ctx.tasks.cancel("read")
ctx.tasks.sleep(0.1) -- wait using a scheduler-owned, cancellable timer

-- During a long CPU loop in poll/logic/a spawned task:
ctx.tasks.yield()
```

Spawning the same local name replaces/cancels its previous task. The returned
handle is that local name. Names starting `__` belong to the kernel. Disabling
the app cancels all its tasks; a late native response cannot resume a cancelled
coroutine. Cancellation does not undo native Java work already submitted.
Scheduler-managed sleeps/timers are cancelled too; timers created directly with
`os.startTimer` are outside that ownership and should be managed by their caller.
`os.pullEvent`/`os.pullEventRaw` filters work independently in every task.
`ctx.tasks.yield()` schedules a continuation so pending input gets priority.

`ctx.system.cancelSensor()` cancels this app's current `poll` worker;
`ctx.system.restartSensor()` replaces it with a fresh worker. The block search
uses these around query changes and Stop to invalidate in-flight scan results.

## Storage service

```lua
local storage = ctx.services.get("storage")

storage.stock("iron", function(ok, data, err)
    -- data.items
end)

storage.withdraw("minecraft:iron_ingot", 16, callback)
storage.deposit("minecraft:cobblestone", 64, callback)
storage.playerInventory(callback) -- data.slots and data.capacity
storage.depositSlot(12, callback) -- deposits the complete stack in slot 12
storage.restock({name = "minecraft:bread", displayName = "Хлеб"}) -- opens the quantity panel
storage.craft("minecraft:precision_mechanism", 1, callback)
storage.inspect({
    dimension = "minecraft:overworld", x = 10, y = 64, z = -20
}, callback)
```

All bridge calls are asynchronous; callbacks receive `(ok, data, error)`.

The bridge also accepts these calls through `storage.request`:

```lua
storage.request("restock_status", {}, callback) -- {rules, intervalMs}
storage.request("restock_set", {
    name = "minecraft:bread", count = 64, enabled = true, label = "Хлеб"
}, callback)
storage.request("restock_toggle", {id = rule.id, enabled = false}, callback)
storage.request("restock_remove", {id = rule.id}, callback)
```

Each rule contains `id`, `owner` (Memory Card UUID), `ownerName`, `name`, `label`,
`count`, `enabled`, plus its last observed `current` and `message`. A registry ID
counts all its variants. Counts must be integers from 1 to 2304; up to 32 rules
are saved. Creating/updating a rule requires an online card owner; pass an
existing `id` to guard against changing the owner while editing. Disabling or
deleting a rule works while its owner is offline. Updates are persisted before
success is returned and failures retain the previous rules. All calls use the
bridge's shared-key/trusted-ID checks. The worker makes no queued withdrawal
requests: it reads the current inventory again before each capped transfer.

## World block search service

```lua
local search = ctx.services.get("block_search")
search.show() -- Keyboard-based input panel; hide() leaves markers active.
search.start("minecraft:diamond_ore") -- success, normalizedQuery or error
search.start("#c:ores/diamond")
search.status() -- {active, query, radius, actualRadius, intervalMs, total, shown, message, nearest}
search.stop() -- stops polling and removes all world markers
```

The service schedules scans on later kernel updates, never inside an input
callback. `nearest` contains integer `blockX/blockY/blockZ`, center `x/y/z`, and
squared distance from the scan origin. Scan results and wireframes use absolute
world positions, independent of GUI lifetime. Queries are exact registry IDs
or `#tag` IDs; a missing namespace defaults to `minecraft`. Radius and interval
come from `tracker.range` / `tracker.intervalMs`, as with the Environment
Detector. The interval is at least 100ms and respects the Geo Scanner's own
server cooldown plus 50ms; its free/maximum radii also cap the requested radius.
Old explicit radius arguments and separate `blockSearch.range/intervalMs` are
ignored. Continuous scans keep running after `hide()` and update their origin
as the wearer walks. Displayed markers are capped at 32 (default 24).
No storage RPC or full block NBT is read.

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
