-- ===========================================================================
-- Модуль `init_monitor`
--
-- Этот модуль служит точкой входа для библиотеки `lib-monitor`,
-- отвечая за инициализацию и загрузку всех ее компонентов.
-- ===========================================================================

--- @type ModuleManager
local ModuleManager = require "src.module_manager"

-- Проверка и сохранение глобальных зависимостей от AstraAPI
local global_dependencies_to_check = {
    "analyze",
    "astra.reload",
    "astra.version",
    "channel_list",
    "dvb_tune",
    "find_channel",
    "http_request",
    "http_server",
    "init_input",
    "json.decode",
    "json.encode",
    "kill_channel",
    "kill_input",
    "make_channel",
    "parse_url",
    "string.split",
    "timer",
    "utils",
    "utils.hostname",
    "utils.ifaddrs",
    "log",
    "dvb_input_instance_list"
}

local found_astra_deps = {}
local all_astra_deps_found = true

for _, dep_path in ipairs(global_dependencies_to_check) do
    local obj = ModuleManager.check_nested_dependency(dep_path)
    
    if obj == nil then
        print(string.format("[Init] Critical dependency missing: %s", dep_path))
        all_astra_deps_found = false
    else
        found_astra_deps[dep_path] = obj
    end
end

if not all_astra_deps_found then
    return false
end

-- Установка найденных Astra-специфичных глобальных зависимостей в ModuleManager
ModuleManager.set_global_dependencies(found_astra_deps)

-- Регистрация модулей
ModuleManager.register_module("monitor_config", "src.config.monitor_config")

ModuleManager.register_module("logger", "src.utils.logger", {"monitor_config"})
ModuleManager.register_module("utils", "src.utils.utils", {"logger", "monitor_config"})

ModuleManager.register_module("http_subscriber", "src.utils.http_subscriber", {"logger", "monitor_config"})

ModuleManager.register_module("dvb_tuner", "src.adapters.dvb_tuner", {"logger", "utils", "monitor_config", "http_subscriber"})
ModuleManager.register_module("base_repository", "src.repository.base_repository", {"logger"})
ModuleManager.register_module("dvb_repository", "src.repository.dvb_repository", {"logger", "base_repository"})
ModuleManager.register_module("adapter", "src.adapters.adapter", {"logger", "monitor_config", "dvb_tuner", "dvb_repository"})

ModuleManager.register_module("channel_monitor", "src.channel.channel_monitor", {"logger", "utils", "monitor_config", "http_subscriber"})
ModuleManager.register_module("channel_repository", "src.repository.channel_repository", {"logger", "base_repository"})
ModuleManager.register_module("channel", "src.channel.channel", {"logger", "utils", "monitor_config", "channel_monitor", "channel_repository", "adapter"})

ModuleManager.register_module("resource_monitor", "src.system.resource_monitor", {"logger"})

-- Регистрация HTTP модулей
ModuleManager.register_module("http_helpers", "http.http_helpers", {"logger"})
ModuleManager.register_module("channel_routes", "http.routes.channel_routes", {"logger", "http_helpers", "channel", "channel_repository"})
ModuleManager.register_module("dvb_routes", "http.routes.dvb_routes", {"logger", "http_helpers", "adapter", "dvb_repository"})
ModuleManager.register_module("monitor_routes", "http.routes.monitor_routes", {"logger", "http_helpers", "channel"})
ModuleManager.register_module("system_routes", "http.routes.system_routes", {"logger", "http_helpers", "resource_monitor"})
ModuleManager.register_module("subscriber_routes", "http.routes.subscriber_routes", {"logger", "http_helpers"})
ModuleManager.register_module("routes_utils", "http.routes.routes_utils", {"logger", "http_helpers", "channel_repository", "dvb_repository", "monitor_config"})
ModuleManager.register_module("http_server", "http.http_server", {
    "logger", "channel_routes", "monitor_routes", "dvb_routes", "system_routes", "subscriber_routes", "routes_utils"
})

-- Валидация зависимостей
if not ModuleManager.validate_dependencies() then 
    return false
end

-- Загрузка модулей
local success_load, load_error = ModuleManager.load_modules()
if not success_load then
    print(string.format("[Init] Failed to load modules: %s", tostring(load_error)))
    return false
end

-- Инициализация объектов из загруженных модулей
local Logger = ModuleManager.get_module("logger")
local Channel = ModuleManager.get_module("channel")
local Adapter = ModuleManager.get_module("adapter")
local HttpServer = ModuleManager.get_module("http_server")

-- Экспорт основных функций в глобальную область видимости для обратной совместимости
if Channel then
    _G.make_stream = Channel.make_stream
    _G.kill_stream = Channel.kill_stream
    _G.make_monitor = Channel.make_monitor
    _G.kill_monitor = Channel.kill_monitor
    _G.pause_monitor = Channel.pause_monitor
    _G.resume_monitor = Channel.resume_monitor
    _G.update_monitor_parameters = Channel.update_monitor_parameters
end

if Adapter then
    _G.dvb_tuner_monitor = Adapter.dvb_tuner_monitor
    _G.pause_dvb_monitor = Adapter.pause_dvb_monitor
    _G.resume_dvb_monitor = Adapter.resume_dvb_monitor
    _G.update_dvb_monitor_parameters = Adapter.update_dvb_monitor_parameters
end

if HttpServer then
    _G.server_start = HttpServer.start
end

if Logger then
    Logger.info("Init", "Library lib-monitor successfully initialized")
end


return ModuleManager
