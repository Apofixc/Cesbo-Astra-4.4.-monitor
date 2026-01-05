--- @class RoutesUtils
local RoutesUtils = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local table_insert = table.insert
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local ChannelStorage = ModuleManager.get_module("channel_storage")
local DvbStorage = ModuleManager.get_module("dvb_storage")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Utils = ModuleManager.get_module("utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local channel_list = ModuleManager.get_global_dependency("channel_list")
local dvb_list = ModuleManager.get_global_dependency("dvb_list")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "RoutesUtils"

--- Возвращает статистику использования ресурсов мониторинга
--- @param server table
--- @param client table
--- @param request table
function RoutesUtils.get_resource_stats(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local active_monitors = 0
    local active_channels = ChannelStorage and ChannelStorage.get_all and ChannelStorage.get_all() or {}
    for _ in pairs(active_channels) do active_monitors = active_monitors + 1 end

    local active_dvb = 0
    local active_adapters = DvbStorage and DvbStorage.get_all and DvbStorage.get_all() or {}
    for _ in pairs(active_adapters) do active_dvb = active_dvb + 1 end

    local total_astra_channels = 0
    if channel_list then
        for _ in pairs(channel_list) do total_astra_channels = total_astra_channels + 1 end
    end

    local total_astra_adapters = 0
    if dvb_list then
        for _ in pairs(dvb_list) do total_astra_adapters = total_astra_adapters + 1 end
    end

    local channel_limit = MonitorConfig and MonitorConfig.ChannelMonitorLimit or 200
    local dvb_limit = MonitorConfig and MonitorConfig.DvbMonitorLimit or 20

    HttpHelpers.success(server, client, {
        monitors = {
            active = active_monitors,
            total_capacity = channel_limit,
            usage_percent = (active_monitors / channel_limit) * 100
        },
        dvb_monitors = {
            active = active_dvb,
            total_capacity = dvb_limit,
            usage_percent = (active_dvb / dvb_limit) * 100
        },
        system = {
            total_astra_channels = total_astra_channels,
            total_astra_adapters = total_astra_adapters
        }
    })
end

--- Возвращает расширенную информацию обо всех каналах
--- @param server table
--- @param client table
--- @param request table
function RoutesUtils.get_channels_extended(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local result = {}
    local list = channel_list or {}

    for _, ch_data in pairs(list) do
        local cfg = ch_data.config or {}
        local name = cfg.name
        if name then
            local ch_obj = ChannelStorage and ChannelStorage.find(name)
            local item = {
                name = name,
                display_name = ch_obj and ch_obj.display_name or name,
                has_monitor = ch_obj ~= nil,
                monitor_type = ch_obj and ch_obj._config and ch_obj._config.monitor_type,
                inputs = cfg.input or {},
                outputs = cfg.output or {}
            }
            if ch_obj and ch_obj._status then
                item.monitor_status = {
                    ready = ch_obj._status.ready,
                    bitrate = ch_obj._status.bitrate,
                    cc_errors = ch_obj._status.cc_errors
                }
            end
            table_insert(result, item)
        end
    end

    HttpHelpers.success(server, client, result)
end

--- Возвращает историю ошибок для монитора (заглушка)
--- @param server table
--- @param client table
--- @param request table
function RoutesUtils.get_monitor_errors(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.path:match("/api/utils/monitors/([^/]+)/errors")
    if not name then return HttpHelpers.error(server, client, 400, "Name required") end

    local ch_obj = ChannelStorage and ChannelStorage.find(name)
    if not ch_obj then return HttpHelpers.error(server, client, 404, "Monitor not found") end

    HttpHelpers.success(server, client, {
        name = name,
        display_name = ch_obj.display_name,
        current_status = ch_obj._status or {},
        error_history = {} -- История пока не реализована в базе
    })
end

--- Возвращает конфигурацию системы мониторинга
--- @param server table
--- @param client table
--- @param request table
function RoutesUtils.get_system_config(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    HttpHelpers.success(server, client, MonitorConfig or {})
end

--- Проверяет доступность и статус монитора по имени
--- @param server table
--- @param client table
--- @param request table
function RoutesUtils.check_object(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local name = request.query and request.query.name
    if not name then return HttpHelpers.error(server, client, 400, "Parameter 'name' is required") end

    local ch_obj = ChannelStorage and ChannelStorage.find(name)
    if ch_obj then
        return HttpHelpers.success(server, client, {
            name = name,
            exists = true,
            type = "channel",
            is_active = true,
            state = ch_obj._status and ch_obj._status.ready and 2 or 1,
            details = {
                monitor_type = ch_obj._config and ch_obj._config.monitor_type,
                display_name = ch_obj.display_name
            }
        })
    end

    local dvb_obj = DvbStorage and DvbStorage.find(name)
    if dvb_obj then
        return HttpHelpers.success(server, client, {
            name = name,
            exists = true,
            type = "dvb",
            is_active = true,
            state = dvb_obj._status and dvb_obj._status.status or 0,
            details = {
                format = dvb_obj._config and dvb_obj._config.type,
                source = dvb_obj._config and dvb_obj._config.tp
            }
        })
    end

    HttpHelpers.success(server, client, { name = name, exists = false })
end

--- Возвращает список всех объектов (мониторы + адаптеры)
--- @param server table
--- @param client table
--- @param request table
function RoutesUtils.get_all_objects(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    local objects = {}
    
    local active_channels = ChannelStorage and ChannelStorage.get_all and ChannelStorage.get_all() or {}
    for name, ch_obj in pairs(active_channels) do
        table_insert(objects, {
            id = name,
            name = name,
            type = "channel_monitor",
            display_name = ch_obj.display_name,
            active = true,
            state = ch_obj._status and ch_obj._status.ready and 2 or 1
        })
    end

    local active_adapters = DvbStorage and DvbStorage.get_all and DvbStorage.get_all() or {}
    for name, dvb_obj in pairs(active_adapters) do
        table_insert(objects, {
            id = name,
            name = name,
            type = "dvb_monitor",
            adapter_name = name,
            active = true,
            state = dvb_obj._status and dvb_obj._status.status or 0,
            source = dvb_obj._config and dvb_obj._config.tp
        })
    end

    HttpHelpers.success(server, client, {
        total = #objects,
        objects = objects
    })
end

--- Очищает неактивные мониторы (заглушка)
--- @param server table
--- @param client table
--- @param request table
function RoutesUtils.cleanup(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    HttpHelpers.success(server, client, {
        message = "Cleanup functionality is temporarily disabled for safety",
        cleaned_count = 0,
        cleaned_objects = {}
    })
end

--- Возвращает информацию о версии API
--- @param server table
--- @param client table
--- @param request table
function RoutesUtils.get_api_info(server, client, request)
    if not request then return nil end
    if not HttpHelpers.check_auth(server, client, request) then return end

    HttpHelpers.success(server, client, {
        api_version = "1.0.0",
        library_version = "2.3.1",
        supported_methods = {"GET", "POST"},
        requires_auth = true,
        auth_header = "X-Api-Key",
        default_port = 8080,
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
end

return RoutesUtils
