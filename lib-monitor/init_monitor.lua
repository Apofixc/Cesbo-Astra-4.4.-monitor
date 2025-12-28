-- ===========================================================================
-- Модуль `init_monitor`
--
-- Этот модуль является точкой входа для инициализации и загрузки всех
-- необходимых компонентов библиотеки `lib-monitor`. Он обеспечивает
-- подключение основных утилит, адаптеров, модулей каналов, HTTP-сервера
-- и диспетчеров мониторинга.
-- ===========================================================================

local ModuleManager = require "src.module_manager"

-- Регистрация модулей
ModuleManager.register_module("utils.logger", "src.utils.logger")
ModuleManager.register_module("config.monitor_config", "src.config.monitor_config")
ModuleManager.register_module("config.monitor_settings", "src.config.monitor_settings")
ModuleManager.register_module("utils.utils", "src.utils.utils", {"utils.logger"})

ModuleManager.register_module("adapters.adapter", "src.adapters.adapter", {"utils.logger", "utils.utils"})
ModuleManager.register_module("dispatchers.dvb_monitor_dispatcher", "src.dispatchers.dvb_monitor_dispatcher", {"utils.logger", "utils.utils"})
ModuleManager.register_module("adapters.dvb_tuner", "src.adapters.dvb_tuner", {"utils.logger", "utils.utils", "config.monitor_config"})

ModuleManager.register_module("channel.channel", "src.channel.channel", {"utils.logger", "utils.utils", "adapters.adapter"})
ModuleManager.register_module("dispatchers.channel_monitor_dispatcher", "src.dispatchers.channel_monitor_dispatcher", {"utils.logger", "utils.utils", "channel.channel"})
ModuleManager.register_module("channel.channel_monitor", "src.channel.channel_monitor", {"utils.logger", "utils.utils", "config.monitor_config"})

ModuleManager.register_module("system.resource_monitor", "src.system.resource_monitor", {"utils.logger", "utils.utils"})

ModuleManager.register_module("http.http_helpers", "http.http_helpers", {"utils.logger", "utils.utils", "config.monitor_config"})
ModuleManager.register_module("http.routes.channel_routes", "http.routes.channel_routes", {"channel.channel", "http.http_helpers"})
ModuleManager.register_module("http.routes.dvb_routes", "http.routes.dvb_routes", {"http.http_helpers"})
ModuleManager.register_module("http.routes.system_routes", "http.routes.system_routes", {"http.http_helpers", "system.resource_monitor"})
ModuleManager.register_module("http.http_server", "http.http_server", {"utils.logger", "utils.utils"})

-- Валидация зависимостей
if not ModuleManager.validate_dependencies() then return end

-- Загрузка модулей
if not ModuleManager.load_modules() then return end

-- Проверка и сохранение глобальных зависимостей от AstraAPI
local global_dependencies_to_check = {
    "channel_list",
    "find_channel",
    "make_channel",
    "kill_channel",
    "parse_url",
    "init_input",
    "kill_input",
    "dvb_tune",
    "string.split",
    "analyze",    
    "utils.hostname",
    "http_request",    
    "http_server",
    "json.encode",
    "json.decode",
    "timer",
    "astra.reload",
    "astra.version",
}

local found_astra_deps = {}
local all_astra_deps_found = true

for _, dep_path in ipairs(global_dependencies_to_check) do
    local obj, success = ModuleManager.check_nested_dependency(dep_path)
    
    if not success then
        all_astra_deps_found = false
        return
    end
    found_astra_deps[dep_path] = obj
end

if not all_astra_deps_found then
    return
end

-- Установка найденных Astra-специфичных глобальных зависимостей в ModuleManager
ModuleManager.set_global_dependencies(found_astra_deps)
