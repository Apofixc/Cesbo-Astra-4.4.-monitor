--- @class RoutesUtils
local RoutesUtils = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local type = type
local table_insert = table.insert
local pcall = pcall

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ChannelRepository = ModuleManager.get_module("channel_repository")
local DvbRepository = ModuleManager.get_module("dvb_repository")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local channel_list = ModuleManager.get_global_dependency("channel_list")
local dvb_input_instance_list = ModuleManager.get_global_dependency("dvb_input_instance_list")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "RoutesUtils"

--- Возвращает статистику использования ресурсов мониторинга
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function RoutesUtils.get_resource_stats(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local active_channels = ChannelRepository and ChannelRepository:get_all() or {}
    local active_adapters = DvbRepository and DvbRepository:get_all() or {}

    local channel_count = 0
    for _ in pairs(active_channels) do channel_count = channel_count + 1 end

    local adapter_count = 0
    for _ in pairs(active_adapters) do adapter_count = adapter_count + 1 end

    local astra_channels = 0
    if channel_list then
        for _ in pairs(channel_list) do astra_channels = astra_channels + 1 end
    end

    local astra_adapters = 0
    if dvb_input_instance_list then
        for _ in pairs(dvb_input_instance_list) do astra_adapters = astra_adapters + 1 end
    end

    HttpHelpers.success(server, client, {
        monitors = {
            active = channel_count,
            total_capacity = MonitorConfig.ChannelMonitorLimit or 200,
            usage_percent = (channel_count / (MonitorConfig.ChannelMonitorLimit or 200)) * 100
        },
        dvb_monitors = {
            active = adapter_count,
            total_capacity = MonitorConfig.DvbMonitorLimit or 20,
            usage_percent = (adapter_count / (MonitorConfig.DvbMonitorLimit or 20)) * 100
        },
        system = {
            total_astra_channels = astra_channels,
            total_astra_adapters = astra_adapters
        }
    })
    return true
end

--- Возвращает расширенную информацию обо всех каналах
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function RoutesUtils.get_channels_extended(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local result = {}
    local list = channel_list or {}

    for _, ch_data in pairs(list) do
        local cfg = ch_data.config or {}
        local name = cfg.name
        if name then
            local ch_obj = ChannelRepository and ChannelRepository:find(name)
            local item = {
                name = name,
                display_name = ch_obj and ch_obj._display_name or name,
                has_monitor = ch_obj ~= nil,
                monitor_type = ch_obj and ch_obj._config and ch_obj._config.monitor_type or "none",
                inputs = cfg.input or {},
                outputs = cfg.output or {},
                monitor_status = ch_obj and ch_obj._status or nil
            }
            table_insert(result, item)
        end
    end

    HttpHelpers.success(server, client, result)
    return true
end

--- Возвращает историю ошибок для монитора
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function RoutesUtils.get_monitor_errors(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then
        return HttpHelpers.error(server, client, 404, "Monitor not found")
    end

    HttpHelpers.success(server, client, {
        name = params.name,
        display_name = ch_obj._display_name,
        current_status = ch_obj._status,
        error_history = {} -- Заглушка для будущей реализации
    })
    return true
end

--- Возвращает текущую конфигурацию системы
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function RoutesUtils.get_system_config(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local config = {}
    for k, v in pairs(MonitorConfig) do
        if type(v) ~= "function" and k ~= "ValidationSchema" then
            config[k] = v
        end
    end

    HttpHelpers.success(server, client, config)
    return true
end

--- Проверяет существование и статус объекта
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function RoutesUtils.check_object(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local name = params.name
    local ch_obj = ChannelRepository and ChannelRepository:find(name)
    local dvb_obj = DvbRepository and DvbRepository:find(name)

    if ch_obj then
        HttpHelpers.success(server, client, {
            name = name,
            exists = true,
            type = "channel",
            is_active = true,
            state = ch_obj._state,
            details = {
                display_name = ch_obj._display_name,
                monitor_type = ch_obj._config.monitor_type
            }
        })
        return true
    elseif dvb_obj then
        HttpHelpers.success(server, client, {
            name = name,
            exists = true,
            type = "dvb",
            is_active = true,
            state = dvb_obj._state,
            details = {
                format = dvb_obj._config.type,
                source = dvb_obj._config.tp
            }
        })
        return true
    end

    HttpHelpers.success(server, client, {
        name = name,
        exists = false
    })
    return true
end

--- Возвращает список всех объектов системы
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function RoutesUtils.get_all_objects(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local objects = {}
    local active_channels = ChannelRepository and ChannelRepository:get_all() or {}
    local active_adapters = DvbRepository and DvbRepository:get_all() or {}

    for name, ch_obj in pairs(active_channels) do
        table_insert(objects, {
            id = name,
            name = name,
            type = "channel_monitor",
            display_name = ch_obj._display_name,
            active = true,
            state = ch_obj._state
        })
    end

    for name, dvb_obj in pairs(active_adapters) do
        table_insert(objects, {
            id = name,
            name = name,
            type = "dvb_monitor",
            adapter_name = name,
            active = true,
            state = dvb_obj._state,
            source = dvb_obj._config.tp
        })
    end

    HttpHelpers.success(server, client, {
        total = #objects,
        objects = objects
    })
    return true
end

--- Очистка неактивных ресурсов (заглушка)
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function RoutesUtils.cleanup(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    HttpHelpers.success(server, client, {
        message = "Cleanup functionality is temporarily disabled for safety",
        cleaned_count = 0,
        cleaned_objects = {}
    })
    return true
end

--- Возвращает информацию об API
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
function RoutesUtils.get_api_info(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    HttpHelpers.success(server, client, {
        api_version = "1.1.0",
        library_version = "2.3.2",
        supported_methods = {"GET", "POST", "PATCH", "DELETE"},
        requires_auth = true,
        auth_header = "X-Api-Key",
        parameter_modes = {"Query String", "JSON Body"},
        endpoints = {
            channels = "/api/channels",
            streams = "/api/streams",
            monitors = "/api/monitors",
            dvb = "/api/dvb",
            system = "/api/system",
            subscribers = "/api/subscribers",
            utils = "/api/utils"
        }
    })
    return true
end

return RoutesUtils
