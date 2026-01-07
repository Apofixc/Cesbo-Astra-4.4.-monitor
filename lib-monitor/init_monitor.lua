-- ===========================================================================
-- Модуль `init_monitor`
--
-- Этот модуль служит точкой входа для библиотеки `lib-monitor`,
-- отвечая за инициализацию и загрузку всех ее компонентов.
-- ===========================================================================

-- 1. Стандартные Lua функции
local ipairs = ipairs
local print = print
local type = type
local string_format = string.format

-- 2. Функции из ModuleManager.get_module()
local path_prefix = (... and (...):match("(.-)init_monitor$")) or ""
--- @type ModuleManager
local ModuleManager = require(path_prefix .. "src.core.module_manager")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Проверка и сохранение глобальных зависимостей от Astra API
local global_dependencies_to_check = {
    "analyze",
    "astra.reload",
    "astra.version",
    "channel_list",
    "dvbls",
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
    error("[Init] Critical Astra dependencies missing. Initialization aborted.")
end

-- Установка найденных Astra-специфичных глобальных зависимостей в ModuleManager
ModuleManager.set_global_dependencies(found_astra_deps)

-- Регистрация модулей
ModuleManager.register_module("monitor_config", path_prefix .. "src.config.monitor_config")

ModuleManager.register_module("logger", path_prefix .. "src.utils.logger", {"monitor_config"})
ModuleManager.register_module("utils", path_prefix .. "src.utils.utils", {"logger", "monitor_config"})

ModuleManager.register_module("http_subscriber", path_prefix .. "src.utils.http_subscriber", {"logger", "monitor_config"})

ModuleManager.register_module("event_bus", path_prefix .. "src.core.event_bus")
ModuleManager.register_module("core.base_monitor", path_prefix .. "src.core.base_monitor", {"logger", "utils", "http_subscriber"})
ModuleManager.register_module("core.base_repository", path_prefix .. "src.core.base_repository", {"logger"})

ModuleManager.register_module("dvb_tuner", path_prefix .. "src.adapters.dvb_tuner", {"logger", "utils", "monitor_config", "http_subscriber", "core.base_monitor"})
ModuleManager.register_module("dvb_repository", path_prefix .. "src.repository.dvb_repository", {"logger", "core.base_repository"})
ModuleManager.register_module("adapter", path_prefix .. "src.adapters.adapter", {"logger", "monitor_config", "dvb_tuner", "dvb_repository", "event_bus"})

ModuleManager.register_module("channel_monitor", path_prefix .. "src.channel.channel_monitor", {"logger", "utils", "monitor_config", "http_subscriber", "core.base_monitor"})
ModuleManager.register_module("channel_repository", path_prefix .. "src.repository.channel_repository", {"logger", "core.base_repository"})
ModuleManager.register_module("channel", path_prefix .. "src.channel.channel", {"logger", "utils", "monitor_config", "channel_monitor", "channel_repository", "event_bus", "dvb_repository"})

ModuleManager.register_module("resource_monitor", path_prefix .. "src.system.resource_monitor", {"logger"})

-- Регистрация HTTP модулей
ModuleManager.register_module("http_helpers", path_prefix .. "http.http_helpers", {"logger"})
ModuleManager.register_module("channel_routes", path_prefix .. "http.routes.channel_routes", {"logger", "http_helpers", "channel", "channel_repository"})
ModuleManager.register_module("dvb_routes", path_prefix .. "http.routes.dvb_routes", {"logger", "http_helpers", "adapter", "dvb_repository"})
ModuleManager.register_module("monitor_routes", path_prefix .. "http.routes.monitor_routes", {"logger", "http_helpers", "channel"})
ModuleManager.register_module("system_routes", path_prefix .. "http.routes.system_routes", {"logger", "http_helpers", "resource_monitor"})
ModuleManager.register_module("subscriber_routes", path_prefix .. "http.routes.subscriber_routes", {"logger", "http_helpers"})
ModuleManager.register_module("routes_utils", path_prefix .. "http.routes.routes_utils", {"logger", "http_helpers", "channel_repository", "dvb_repository", "monitor_config"})
ModuleManager.register_module("http_server", path_prefix .. "http.http_server", {
    "logger", "channel_routes", "monitor_routes", "dvb_routes", "system_routes", "subscriber_routes", "routes_utils"
})

-- Валидация зависимостей
if not ModuleManager.validate_dependencies() then 
    error("[Init] Module dependency validation failed.")
end

-- Загрузка модулей
local success_load, load_error = ModuleManager.load_modules()
if not success_load then
    error(string.format("[Init] Failed to load modules: %s", tostring(load_error)))
end

-- Инициализация объектов из загруженных модулей
local Logger = ModuleManager.get_module("logger")
local Channel = ModuleManager.get_module("channel")
local Adapter = ModuleManager.get_module("adapter")
local HttpServer = ModuleManager.get_module("http_server")

-- Экспорт основных функций в глобальную область видимости для обратной совместимости
if type(Channel) == "table" then
    _G.make_stream = Channel.make_stream
    _G.kill_stream = Channel.kill_stream
    _G.make_monitor = Channel.make_monitor
    _G.kill_monitor = Channel.kill_monitor
    _G.pause_monitor = Channel.pause_monitor
    _G.resume_monitor = Channel.resume_monitor
    _G.update_monitor_parameters = Channel.update_monitor_parameters
end

if type(Adapter) == "table" then
    _G.dvb_tuner_monitor = Adapter.dvb_tuner_monitor
    _G.pause_dvb_monitor = Adapter.pause_dvb_monitor
    _G.resume_dvb_monitor = Adapter.resume_dvb_monitor
    _G.update_dvb_monitor_parameters = Adapter.update_dvb_monitor_parameters
end

if type(HttpServer) == "table" then
    _G.server_start = HttpServer.start
    _G.server_stop = HttpServer.stop
end

if Logger then
    Logger.info("Init", "Библиотека lib-monitor успешно инициализирована")
end

return ModuleManager
