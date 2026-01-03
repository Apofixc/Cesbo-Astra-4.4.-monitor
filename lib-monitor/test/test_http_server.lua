--- Тестовый скрипт для проверки HTTP сервера lib-monitor
-- Запуск: /opt/astra/astra4.4.182 /opt/astra/lib-monitor/test/test_http_server.lua

-- Эмуляция ModuleManager для теста
_G.ModuleManager = {
    modules = {},
    global_dependencies = {
        ["astra.version"] = "4.4.182",
        ["json.encode"] = function(v) return "{\"status\":\"ok\"}" end, -- Упрощенная эмуляция
        ["json.decode"] = function(v) return {} end,
        ["http_server"] = function(conf) 
            print("[Test] http_server called with port: " .. conf.port)
            for _, r in ipairs(conf.route) do
                print("[Test] Registered route: " .. r[1])
            end
            return true 
        end,
        ["log.info"] = function(c, m, ...) print("[INFO]["..c.."] " .. string.format(m, ...)) end,
        ["log.error"] = function(c, m, ...) print("[ERROR]["..c.."] " .. string.format(m, ...)) end,
    }
}

function ModuleManager.get_module(name)
    if ModuleManager.modules[name] then return ModuleManager.modules[name] end
    local path = "astra/lib-monitor/http/" .. name .. ".lua"
    if name:match("_routes") then
        path = "astra/lib-monitor/http/routes/" .. name .. ".lua"
    elseif name == "logger" then
        return { 
            info = ModuleManager.global_dependencies["log.info"],
            error = ModuleManager.global_dependencies["log.error"],
            with_error = function(f, ...) return f(...) end
        }
    end
    
    local chunk = loadfile(path)
    if chunk then
        local mod = chunk()
        ModuleManager.modules[name] = mod
        return mod
    end
    return nil
end

function ModuleManager.get_global_dependency(name)
    return ModuleManager.global_dependencies[name]
end

-- Загрузка и запуск сервера
local HttpServer = ModuleManager.get_module("http_server")
if HttpServer then
    HttpServer.start("0.0.0.0", 8080)
    print("[Test] HTTP Server initialization test passed")
else
    print("[Test] Failed to load HttpServer")
end

astra.exit()
