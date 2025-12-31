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
    "utils.hostname",
    "log"
}

local found_astra_deps = {}
local all_astra_deps_found = true

for _, dep_path in ipairs(global_dependencies_to_check) do
    local success, obj = ModuleManager.check_nested_dependency(dep_path)
    
    if not success then
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
ModuleManager.register_module("monitor_settings", "src.config.monitor_settings")

ModuleManager.register_module("logger", "src.utils.logger", {"monitor_config"})
ModuleManager.register_module("utils", "src.utils.utils", {"logger", "monitor_settings"})

ModuleManager.register_module("event_dispatcher", "src.utils.event_dispatcher", {"logger"})
ModuleManager.register_module("http_subscriber", "src.utils.http_subscriber", {"logger", "monitor_settings", "event_dispatcher"})

ModuleManager.register_module("dvb_tuner", "src.adapters.dvb_tuner", {"logger", "utils", "monitor_config", "event_dispatcher"})
ModuleManager.register_module("dvb_storage", "src.storage.dvb_storage", {"logger"})
ModuleManager.register_module("adapter", "src.adapters.adapter", {"logger", "monitor_config", "dvb_tuner", "dvb_storage"})

ModuleManager.register_module("channel_monitor", "src.channel.channel_monitor", {"logger", "utils", "monitor_config", "event_dispatcher"})
ModuleManager.register_module("channel_storage", "src.storage.channel_storage", {"logger"})
ModuleManager.register_module("channel", "src.channel.channel", {"logger", "utils", "monitor_config", "channel_monitor", "channel_storage", "adapter"})

ModuleManager.register_module("resource_monitor", "src.system.resource_monitor", {"logger"})

-- Валидация зависимостей
if not ModuleManager.validate_dependencies() then 
    return false
end

-- Загрузка модулей
local success_load, load_error = ModuleManager.load_modules()
if not success_load then
    return false
end

-- Инициализация объектов из загруженных модулей
local Logger = ModuleManager.get_module("logger")

if not success_load then
    if Logger then
        Logger.error("Init", "Failed to load modules: %s", tostring(load_error))
    end
    return false
end

-- Инициализация подписчиков
local HttpSubscriber = ModuleManager.get_module("http_subscriber")
if HttpSubscriber then
    HttpSubscriber.init()
end

return ModuleManager
