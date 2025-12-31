-- ===========================================================================
-- Модуль `init_monitor`
--
-- Этот модуль служит точкой входа для библиотеки `lib-monitor`,
-- отвечая за инициализацию и загрузку всех ее компонентов.
-- Он обеспечивает подключение основных утилит, адаптеров, модулей каналов,
-- HTTP-сервера и диспетчеров мониторинга для полноценной работы системы.
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
}

local found_astra_deps = {}
local all_astra_deps_found = true

for _, dep_path in ipairs(global_dependencies_to_check) do
    local obj, success = ModuleManager.check_nested_dependency(dep_path)
    
    if not success then
        all_astra_deps_found = false
        break
    else
        found_astra_deps[dep_path] = obj
    end
end

if not all_astra_deps_found then
     print("[ERROR] Some Astra dependencies are missing")
    return false
end

-- Установка найденных Astra-специфичных глобальных зависимостей в ModuleManager
ModuleManager.set_global_dependencies(found_astra_deps)

-- Регистрация модулей
ModuleManager.register_module("monitor_config", "src.config.monitor_config")
ModuleManager.register_module("monitor_settings", "src.config.monitor_settings")

ModuleManager.register_module("logger", "src.utils.logger")
ModuleManager.register_module("utils", "src.utils.utils", {"logger", "monitor_config", "monitor_settings"})

ModuleManager.register_module("dvb_tuner", "src.adapters.dvb_tuner", {"logger", "utils", "monitor_config"})
ModuleManager.register_module("adapter", "src.adapters.adapter", {"logger", "dvb_tuner", "dvb_monitor_dispatcher"})
ModuleManager.register_module("dvb_monitor_dispatcher", "src.dispatchers.dvb_monitor_dispatcher", {"logger", "utils", "dvb_tuner", "monitor_config"})

ModuleManager.register_module("channel_monitor", "src.channel.channel_monitor", {"logger", "utils", "monitor_config"})
ModuleManager.register_module("channel", "src.channel.channel", {"logger", "utils", "adapter", "channel_monitor", "channel_monitor_dispatcher", "monitor_config"})
ModuleManager.register_module("channel_monitor_dispatcher", "src.dispatchers.channel_monitor_dispatcher", {"logger", "channel_monitor", "monitor_config", "utils"})

ModuleManager.register_module("resource_monitor", "src.system.resource_monitor", {"logger"})

-- ModuleManager.register_module("http.http_helpers", "http.http_helpers", {"logger", "utils"})
-- ModuleManager.register_module("http.routes.channel_routes", "http.routes.channel_routes", {"logger", "channel_monitor_dispatcher", "channel", "http_helpers", "utils"})
-- ModuleManager.register_module("http.routes.dvb_routes", "http.routes.dvb_routes", {"logger", "http_helpers", "dvb_monitor_dispatcher"})
-- ModuleManager.register_module("http.routes.system_routes", "http.routes.system_routes", {"logger", "resource_monitor", "http_helpers"})
-- ModuleManager.register_module("http.http_server", "http.http_server", {"logger", "channel_routes", "dvb_routes", "system_routes", "resource_monitor"})

-- Валидация зависимостей
if not ModuleManager.validate_dependencies() then 
    -- Logger еще не загружен, используем print
    print("[ERROR] Валидация зависимостей модуля не удалась")
    return false
end

-- Загрузка модулей
if not ModuleManager.load_modules() then
    -- Logger еще не загружен, используем print
    print("[ERROR] Не удалось загрузить модули")
    return false
end
