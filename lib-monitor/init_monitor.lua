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
-- 1. Сначала регистрируем базовые конфигурационные модули (без зависимостей)
ModuleManager.register_module("config.monitor_config", "src.config.monitor_config")
ModuleManager.register_module("config.monitor_settings", "src.config.monitor_settings")

-- 2. Регистрируем утилиты (зависит только от конфигурации)
ModuleManager.register_module("utils.logger", "src.utils.logger")
ModuleManager.register_module("utils.utils", "src.utils.utils", {"utils.logger"})

-- 3. Регистрируем адаптеры (зависят от утилит)
ModuleManager.register_module("adapters.adapter", "src.adapters.adapter", {"utils.logger", "utils.utils"})
ModuleManager.register_module("adapters.dvb_tuner", "src.adapters.dvb_tuner", {
    "utils.logger", 
    "utils.utils", 
    "config.monitor_config"
})

-- 4. Регистрируем диспетчеры (зависят от утилит и адаптеров)
ModuleManager.register_module("dispatchers.dvb_monitor_dispatcher", "src.dispatchers.dvb_monitor_dispatcher", {
    "utils.logger", 
    "utils.utils"
})
ModuleManager.register_module("dispatchers.channel_monitor_dispatcher", "src.dispatchers.channel_monitor_dispatcher", {
    "utils.logger", 
    "utils.utils", 
    "channel.channel"
})

-- 5. Регистрируем модули каналов (зависят от утилит и адаптеров)
ModuleManager.register_module("channel.channel", "src.channel.channel", {
    "utils.logger", 
    "utils.utils", 
    "adapters.adapter"
})
ModuleManager.register_module("channel.channel_monitor", "src.channel.channel_monitor", {
    "utils.logger", 
    "utils.utils", 
    "config.monitor_config"
})

-- 6. Регистрируем системные модули (зависят от утилит)
ModuleManager.register_module("system.resource_monitor", "src.system.resource_monitor", {
    "utils.logger", 
    "utils.utils"
})

-- 7. Регистрируем HTTP-хелперы (зависят от утилит и конфигурации)
ModuleManager.register_module("http.http_helpers", "http.http_helpers", {
    "utils.logger", 
    "utils.utils", 
    "config.monitor_config"
})

-- 8. Регистрируем HTTP-роуты (зависят от соответствующих модулей и хелперов)
ModuleManager.register_module("http.routes.channel_routes", "http.routes.channel_routes", {
    "channel.channel", 
    "http.http_helpers"
})
ModuleManager.register_module("http.routes.dvb_routes", "http.routes.dvb_routes", {
    "http.http_helpers"
})
ModuleManager.register_module("http.routes.system_routes", "http.routes.system_routes", {
    "http.http_helpers", 
    "system.resource_monitor"
})

-- 9. Регистрируем HTTP-сервер (зависит от утилит)
ModuleManager.register_module("http.http_server", "http.http_server", {
    "utils.logger", 
    "utils.utils"
})

-- Валидация зависимостей
if not ModuleManager.validate_dependencies() then 
    print("[ERROR] Module dependencies validation failed")
    return false
end

-- Загрузка модулей
if not ModuleManager.load_modules() then
    print("[ERROR] Failed to load modules")
    return false
end

local Logger = ModuleManager.get_module("utils.logger")
local MonitorConfig = ModuleManager.get_module("config.monitor_config")

-- Проверяем, что модули загружены
if not Logger then
    print("[ERROR] Logger module not loaded")
    return false
end

if not MonitorConfig then
    print("[ERROR] MonitorConfig module not loaded")
    return false
end

-- Устанавливаем уровень логирования из конфигурации
if MonitorConfig.LogLevel and Logger.set_log_level then
    Logger.set_log_level(MonitorConfig.LogLevel)
    Logger.info("ModuleManager", "Log level set to: %s", MonitorConfig.LogLevel)
end

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
}

local found_astra_deps = {}
local all_astra_deps_found = true

for _, dep_path in ipairs(global_dependencies_to_check) do
    local obj, success = ModuleManager.check_nested_dependency(dep_path)
    
    if not success then
        Logger.error("ModuleManager", "Missing Astra dependency: %s", dep_path)
        all_astra_deps_found = false
    else
        found_astra_deps[dep_path] = obj
        Logger.debug("ModuleManager", "Found Astra dependency: %s", dep_path)
    end
end

if not all_astra_deps_found then
    Logger.error("ModuleManager", "Some Astra dependencies are missing")
    return false
end

-- Установка найденных Astra-специфичных глобальных зависимостей в ModuleManager
ModuleManager.set_global_dependencies(found_astra_deps)
