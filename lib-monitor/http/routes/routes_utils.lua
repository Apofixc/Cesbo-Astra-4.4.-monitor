--- @class RoutesUtils
local RoutesUtils = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert
local type = type

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

--- Валидация входных данных
--- @param params table Таблица параметров
--- @param schema table Схема валидации
--- @return boolean success, string|nil error_message
function RoutesUtils.validate_input(params, schema)
    for field, rules in pairs(schema) do
        if rules.required and params[field] == nil then
            return false, "Отсутствует обязательное поле: " .. field
        end
        if params[field] and rules.type and type(params[field]) ~= rules.type then
            return false, "Некорректный тип поля: " .. field
        end
    end
    return true
end

--- Возвращает статистику использования ресурсов мониторинга
function RoutesUtils.get_resource_stats(server, client, request)
    local channel_count = ChannelRepository and ChannelRepository:count() or 0
    local adapter_count = DvbRepository and DvbRepository:count() or 0

    local astra_channels, astra_adapters = 0, 0
    if channel_list then for _ in pairs(channel_list) do astra_channels = astra_channels + 1 end end
    if dvb_input_instance_list then
        for _ in pairs(dvb_input_instance_list) do astra_adapters = astra_adapters + 1 end
    end

    local limit = MonitorConfig.ChannelMonitorLimit or 200
    local dvb_limit = MonitorConfig.DvbMonitorLimit or 20

    return HttpHelpers.success(server, client, {
        monitors = {
            active = channel_count,
            total_capacity = limit,
            usage_percent = (channel_count / limit) * 100
        },
        dvb_monitors = {
            active = adapter_count,
            total_capacity = dvb_limit,
            usage_percent = (adapter_count / dvb_limit) * 100
        },
        system = { total_astra_channels = astra_channels, total_astra_adapters = astra_adapters }
    })
end

--- Возвращает расширенную информацию обо всех каналах
function RoutesUtils.get_channels_extended(server, client, request)
    local result = {}
    local list = channel_list or {}

    for _, ch_data in pairs(list) do
        local cfg = ch_data.config or {}
        local name = cfg.name
        if name then
            local ch_obj = ChannelRepository and ChannelRepository:find(name)
            table_insert(result, {
                name = name,
                display_name = ch_obj and ch_obj._display_name or name,
                has_monitor = ch_obj ~= nil,
                monitor_type = ch_obj and ch_obj._config and ch_obj._config.monitor_type or "none",
                inputs = cfg.input or {},
                outputs = cfg.output or {},
                monitor_status = ch_obj and ch_obj._status or nil
            })
        end
    end

    return HttpHelpers.success(server, client, result)
end

--- Возвращает историю ошибок для монитора
function RoutesUtils.get_monitor_errors(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    if not ch_obj then return HttpHelpers.error(server, client, 404, "Монитор не найден") end

    return HttpHelpers.success(server, client, {
        name = params.name,
        display_name = ch_obj._display_name,
        current_status = ch_obj._status,
        error_history = {}
    })
end

--- Возвращает текущую конфигурацию системы
function RoutesUtils.get_system_config(server, client, request)
    local config = {}
    for k, v in pairs(MonitorConfig) do
        if type(v) ~= "function" and k ~= "ValidationSchema" then config[k] = v end
    end
    return HttpHelpers.success(server, client, config)
end

--- Проверяет существование и статус объекта
function RoutesUtils.check_object(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    local dvb_obj = DvbRepository and DvbRepository:find(params.name)

    if ch_obj then
        return HttpHelpers.success(server, client, {
            name = params.name, exists = true, type = "channel", is_active = true, state = ch_obj._state,
            details = { display_name = ch_obj._display_name, monitor_type = ch_obj._config.monitor_type }
        })
    elseif dvb_obj then
        return HttpHelpers.success(server, client, {
            name = params.name, exists = true, type = "dvb", is_active = true, state = dvb_obj._state,
            details = { format = dvb_obj._config.type, source = dvb_obj._config.tp }
        })
    end

    return HttpHelpers.success(server, client, { name = params.name, exists = false })
end

--- Возвращает список всех объектов системы
function RoutesUtils.get_all_objects(server, client, request)
    local objects = {}
    local active_channels = ChannelRepository and ChannelRepository:get_all() or {}
    local active_adapters = DvbRepository and DvbRepository:get_all() or {}

    for name, ch_obj in pairs(active_channels) do
        table_insert(objects, {
            id = name, name = name, type = "channel_monitor",
            display_name = ch_obj._display_name, active = true, state = ch_obj._state
        })
    end

    for name, dvb_obj in pairs(active_adapters) do
        table_insert(objects, {
            id = name, name = name, type = "dvb_monitor",
            adapter_name = name, active = true, state = dvb_obj._state, source = dvb_obj._config.tp
        })
    end

    return HttpHelpers.success(server, client, { total = #objects, objects = objects })
end

--- Очистка неактивных ресурсов (заглушка)
function RoutesUtils.cleanup(server, client, request)
    return HttpHelpers.success(server, client, { message = "Отключено в целях безопасности", cleaned_count = 0 })
end

--- Возвращает информацию об API
function RoutesUtils.get_api_info(server, client, request)
    return HttpHelpers.success(server, client, {
        api_version = "1.1.0",
        library_version = "2.3.2",
        supported_methods = {"GET", "POST", "PATCH", "DELETE"},
        endpoints = {
            channels = "/api/channels", streams = "/api/streams", monitors = "/api/monitors",
            dvb = "/api/dvb", system = "/api/system", subscribers = "/api/subscribers", utils = "/api/utils"
        }
    })
end

return RoutesUtils
