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
local pcall = pcall
local error = error
local tostring = tostring

-- 2. Функции из ModuleManager.get_module()
local path_prefix = (... and (...):match("(.-)init_monitor$")) or ""
--- @type ModuleManager
local ModuleManager = require(path_prefix .. "src.core.module_manager")

-- 3. Фазы инициализации
local INIT_PHASES = {
    DEPENDENCIES = 1,
    CORE_MODULES = 2,
    ADAPTERS = 3,
    HTTP = 4,
    FINAL = 5
}

local current_phase = INIT_PHASES.DEPENDENCIES

--- Выполняет инициализацию конкретной фазы с проверкой последовательности.
--- @param phase number Идентификатор фазы
--- @param func function Функция инициализации
--- @return boolean success Статус выполнения
local function initialize_phase(phase, func)
    if phase ~= current_phase then
        error(string_format("Invalid initialization phase: expected %d, got %d",
              current_phase, phase))
    end

    local success, err = pcall(func)
    if not success then
        error(string_format("Phase %d initialization failed: %s", phase, tostring(err)))
    end

    current_phase = current_phase + 1
    return success
end

-- 4. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
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

initialize_phase(INIT_PHASES.DEPENDENCIES, function()
    local found_astra_deps = {}
    local all_astra_deps_found = true

    for _, dep_path in ipairs(global_dependencies_to_check) do
        local obj = ModuleManager.check_nested_dependency(dep_path)

        if obj == nil then
            print(string_format("[Init] Critical dependency missing: %s", dep_path))
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
end)

initialize_phase(INIT_PHASES.CORE_MODULES, function()
    -- Регистрация модулей
    ModuleManager.register_module("monitor_config", path_prefix .. "src.config.monitor_config")
    ModuleManager.register_module("core.scheduler", path_prefix .. "src.core.scheduler", {"logger"})
    ModuleManager.register_module("table_pool", path_prefix .. "src.utils.table_pool", {"logger"})
    ModuleManager.register_module("utils.wildcard", path_prefix .. "src.utils.wildcard")
    ModuleManager.register_module("logger", path_prefix .. "src.utils.logger", {"monitor_config"})
    ModuleManager.register_module("utils", path_prefix .. "src.utils.utils", {"logger", "monitor_config"})
    ModuleManager.register_module("utils.filter_engine", path_prefix .. "src.utils.filter_engine", {"logger"})
    ModuleManager.register_module("ws_subscriber", path_prefix .. "src.utils.ws_subscriber", {"logger"})

    -- Ядро системы
    ModuleManager.register_module("core.base_repository", path_prefix .. "src.core.base_repository", {"logger"})
    ModuleManager.register_module("core.base_monitor", path_prefix .. "src.core.base_monitor",
        {"logger", "utils", "monitor_config", "core.scheduler"})
    ModuleManager.register_module("core.subscription_manager", path_prefix .. "src.core.subscription_manager",
        {"logger", "monitor_config", "utils.filter_engine", "utils.wildcard", "core.scheduler"})
    ModuleManager.register_module("core.event_dispatcher", path_prefix .. "src.core.event_dispatcher",
        {"logger", "core.subscription_manager", "table_pool", "utils", "utils.wildcard", "core.scheduler"})

    ModuleManager.register_module("resource_monitor", path_prefix .. "src.system.resource_monitor",
        {"logger", "core.scheduler", "monitor_config"})

    -- Валидация и загрузка базовых модулей
    if not ModuleManager.validate_dependencies() then
        error("[Init] Module dependency validation failed.")
    end

    if not ModuleManager.load_modules() then
        error("[Init] Failed to load core modules.")
    end
    collectgarbage()

    -- Валидация глобальной конфигурации
    local MonitorConfig = ModuleManager.get_module("monitor_config")
    if MonitorConfig and MonitorConfig.validate then
        local ok, err = MonitorConfig.validate()
        if not ok then
            error(string_format("[Init] Configuration validation failed: %s", tostring(err)))
        end
    end
end)

initialize_phase(INIT_PHASES.ADAPTERS, function()
    ModuleManager.register_module("tuner_monitor", path_prefix .. "src.adapters.tuner_monitor",
        {"logger", "utils", "monitor_config", "core.base_monitor"})
    ModuleManager.register_module("dvb_repository", path_prefix .. "src.repository.dvb_repository",
        {"logger", "core.base_repository"})
    ModuleManager.register_module("adapter", path_prefix .. "src.adapters.adapter",
        {"logger", "monitor_config", "tuner_monitor", "dvb_repository", "core.event_dispatcher"})

    ModuleManager.register_module("channel_monitor", path_prefix .. "src.channel.channel_monitor",
        {"logger", "utils", "monitor_config", "core.base_monitor", "table_pool"})
    ModuleManager.register_module("channel_repository", path_prefix .. "src.repository.channel_repository",
        {"logger", "core.base_repository"})
    ModuleManager.register_module("channel", path_prefix .. "src.channel.channel",
        {"logger", "utils", "monitor_config", "channel_monitor", "channel_repository", "core.event_dispatcher",
        "dvb_repository"})

    if not ModuleManager.load_modules() then
        error("[Init] Failed to load adapter modules.")
    end
    collectgarbage()
end)

initialize_phase(INIT_PHASES.HTTP, function()
    ModuleManager.register_module("http_helpers", path_prefix .. "http.http_helpers", {"logger"})
    ModuleManager.register_module("routes_utils", path_prefix .. "http.routes.routes_utils",
        {"logger", "http_helpers", "channel_repository", "dvb_repository", "monitor_config"})
    ModuleManager.register_module("channel_routes", path_prefix .. "http.routes.channel_routes",
        {"logger", "http_helpers", "channel", "channel_repository", "routes_utils"})
    ModuleManager.register_module("dvb_routes", path_prefix .. "http.routes.dvb_routes",
        {"logger", "http_helpers", "adapter", "dvb_repository", "routes_utils"})
    ModuleManager.register_module("monitor_routes", path_prefix .. "http.routes.monitor_routes",
        {"logger", "http_helpers", "channel", "routes_utils"})
    ModuleManager.register_module("system_routes", path_prefix .. "http.routes.system_routes",
        {"logger", "http_helpers", "resource_monitor"})
    ModuleManager.register_module("subscriber_routes", path_prefix .. "http.routes.subscriber_routes",
        {"logger", "http_helpers", "core.event_dispatcher"})
    ModuleManager.register_module("http_server", path_prefix .. "http.http_server", {
        "logger", "channel_routes", "monitor_routes", "dvb_routes", "system_routes", "subscriber_routes",
        "routes_utils", "ws_subscriber"
    })

    if not ModuleManager.load_modules() then
        error("[Init] Failed to load HTTP modules.")
    end
    collectgarbage()
end)

initialize_phase(INIT_PHASES.FINAL, function()
    local Logger = ModuleManager.get_module("logger")
    local Channel = ModuleManager.get_module("channel")
    local Adapter = ModuleManager.get_module("adapter")
    local HttpServer = ModuleManager.get_module("http_server")
    local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
    local MonitorConfig = ModuleManager.get_module("monitor_config")
    local TablePool = ModuleManager.get_module("utils.table_pool")
    local Scheduler = ModuleManager.get_module("core.scheduler")
    local ChannelRepository = ModuleManager.get_module("channel_repository")
    local DvbRepository = ModuleManager.get_module("dvb_repository")

    -- 1. Инициализация глобального диспетчера событий (Singleton)
    local dispatcher_instance = nil
    if EventDispatcher then
        dispatcher_instance = EventDispatcher.get_instance()
        _G.EventDispatcher = dispatcher_instance
    end

    -- 2. Инициализация подписок на конфигурацию у всех компонентов
    if Logger and Logger.init_config_subscription then Logger.init_config_subscription() end
    if TablePool and TablePool.init_config_subscription then TablePool.init_config_subscription() end
    if dispatcher_instance and dispatcher_instance.init_config_subscription then
        dispatcher_instance:init_config_subscription()
    end
    if Scheduler and Scheduler.get_instance then
        local s = Scheduler.get_instance()
        if s.init_config_subscription then s:init_config_subscription() end
    end
    if ChannelRepository and ChannelRepository.init_config_subscription then
        ChannelRepository:init_config_subscription()
    end
    if DvbRepository and DvbRepository.init_config_subscription then
        DvbRepository:init_config_subscription()
    end

    -- Мониторы и утилиты
    local BaseMonitor = ModuleManager.get_module("core.base_monitor")
    local ChannelMonitor = ModuleManager.get_module("channel_monitor")
    local TunerMonitor = ModuleManager.get_module("tuner_monitor")
    local Wildcard = ModuleManager.get_module("utils.wildcard")
    local FilterEngine = ModuleManager.get_module("utils.filter_engine")
    local ResourceMonitor = ModuleManager.get_module("resource_monitor")

    if BaseMonitor and BaseMonitor.init_config_subscription then BaseMonitor.init_config_subscription() end
    if ChannelMonitor and ChannelMonitor.init_config_subscription then ChannelMonitor.init_config_subscription() end
    if TunerMonitor and TunerMonitor.init_config_subscription then TunerMonitor.init_config_subscription() end
    if Channel and Channel.init_config_subscription then Channel.init_config_subscription() end
    if Wildcard and Wildcard.init_config_subscription then Wildcard.init_config_subscription() end
    if FilterEngine and FilterEngine.init_config_subscription then FilterEngine.init_config_subscription() end
    if ResourceMonitor and ResourceMonitor.init_config_subscription then ResourceMonitor.init_config_subscription() end

    -- 3. Первичная синхронизация конфигурации (передача из JSON в модули через события)
    if MonitorConfig and dispatcher_instance then
        Logger.info("Init", "Выполнение первичной синхронизации конфигурации...")
        for section_name, section_data in pairs(MonitorConfig) do
            if type(section_data) == "table" and section_name ~= "ValidationSchema" and section_name ~= "STREAM" then
                dispatcher_instance:emit_safe("config:updated:" .. section_name:lower(), section_data)
            end
        end
    end

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
        _G.switch_transponder = Adapter.switch_transponder
        _G.stop_dependent_channels = Adapter.stop_dependent_channels
        _G.start_dependent_channels = Adapter.start_dependent_channels
    end

    if type(HttpServer) == "table" then
        _G.server_start = HttpServer.start
        _G.server_stop = HttpServer.stop
    end

    if Logger then
        Logger.info("Init", "Библиотека lib-monitor успешно инициализирована")
    end

    collectgarbage()
end)

local shutdown_handlers = {}

--- Регистрирует обработчик для корректного завершения работы.
--- @param name string Уникальное имя обработчика
--- @param handler function Функция очистки ресурсов
function add_shutdown_handler(name, handler)
    shutdown_handlers[name] = handler
end

--- Выполняет корректное завершение работы библиотеки.
--- Вызывает все зарегистрированные обработчики в обратном порядке.
function graceful_shutdown()
    local Logger = ModuleManager.get_module("logger")
    if Logger then Logger.info("Init", "Starting graceful shutdown...") end

    -- Получаем список имен и сортируем их в обратном порядке для детерминированного завершения
    local names = {}
    for name in pairs(shutdown_handlers) do
        table.insert(names, name)
    end
    table.sort(names, function(a, b) return a > b end)

    for _, name in ipairs(names) do
        if Logger then Logger.debug("Init", "Executing shutdown handler: %s", name) end
        local ok, err = pcall(shutdown_handlers[name])
        if not ok and Logger then
            Logger.error("Init", "Shutdown handler '%s' failed: %s", name, tostring(err))
        end
    end

    if Logger then Logger.info("Init", "Graceful shutdown completed") end
    collectgarbage()
end

-- Регистрация базовых обработчиков
add_shutdown_handler("10_http_server", function()
    local HttpServer = ModuleManager.get_module("http_server")
    if HttpServer and HttpServer.stop then
        HttpServer.stop()
    end
end)

add_shutdown_handler("15_ws_subscriber", function()
    local WsSubscriber = ModuleManager.get_module("ws_subscriber")
    if WsSubscriber and WsSubscriber.shutdown then
        WsSubscriber.shutdown()
    end
end)

add_shutdown_handler("20_repositories", function()
    local ChannelRepository = ModuleManager.get_module("channel_repository")
    local DvbRepository = ModuleManager.get_module("dvb_repository")

    if ChannelRepository and ChannelRepository.shutdown then
        ChannelRepository:shutdown()
    end

    if DvbRepository and DvbRepository.shutdown then
        DvbRepository:shutdown()
    end
end)

add_shutdown_handler("30_event_dispatcher", function()
    local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
    if EventDispatcher then
        local instance = EventDispatcher.get_instance()
        if instance and instance.shutdown then
            instance:shutdown()
        end
    end
end)

add_shutdown_handler("40_resource_monitor", function()
    local ResourceMonitor = ModuleManager.get_module("resource_monitor")
    if ResourceMonitor and ResourceMonitor.stop then
        ResourceMonitor.stop()
    end
end)

add_shutdown_handler("50_table_pool", function()
    local TablePool = ModuleManager.get_module("table_pool")
    if TablePool and TablePool.shutdown then
        TablePool.shutdown()
    end
end)

add_shutdown_handler("99_scheduler", function()
    local Scheduler = ModuleManager.get_module("core.scheduler")
    if Scheduler then
        local instance = Scheduler.get_instance()
        if instance and instance.shutdown then
            instance:shutdown()
        end
    end
end)

_G.add_shutdown_handler = add_shutdown_handler
_G.graceful_shutdown = graceful_shutdown

return ModuleManager
