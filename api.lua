-- Public app API. Third-party apps return a descriptor consumed by registerApp.
local api = {
    version = 1,
    _apps = {}
}

function api.registerApp(definition)
    assert(type(definition) == "table", "app definition must be a table")
    assert(type(definition.id) == "string", "app.id is required")
    assert(not api._apps[definition.id], "duplicate app id: " .. definition.id)
    api._apps[definition.id] = definition
    return definition
end

function api.getApps()
    return api._apps
end

return api
