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
--- @return boolean Статус валидации
--- @return string|nil Сообщение об ошибке
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
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
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
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
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
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
function RoutesUtils.get_monitor_errors(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, {
        name = { type = "string", required = true },
        limit = { type = "number", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    local dvb_obj = DvbRepository and DvbRepository:find(params.name)
    local obj = ch_obj or dvb_obj

    if not obj then return HttpHelpers.error(server, client, 404, "Объект не найден") end

    local limit = params.limit or 50
    local logs = {}
    if Logger and Logger.get_buffer then
        -- Запрашиваем логи для компонента (имя монитора)
        local all_logs = Logger.get_buffer(params.name, limit)
        for _, entry in ipairs(all_logs) do
            if entry.level == "ERROR" or entry.level == "WARN" then
                table_insert(logs, entry)
            end
        end
    end

    return HttpHelpers.success(server, client, {
        name = params.name,
        display_name = obj._display_name or params.name,
        current_status = obj:get_status_table(),
        error_history = logs
    })
end

--- Возвращает текущую конфигурацию системы
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
function RoutesUtils.get_system_config(server, client, request)
    local config = {}
    for k, v in pairs(MonitorConfig) do
        if type(v) ~= "function" and k ~= "ValidationSchema" then config[k] = v end
    end
    return HttpHelpers.success(server, client, config)
end

--- Проверяет существование и статус объекта
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
function RoutesUtils.check_object(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = HttpHelpers.validate(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local ch_obj = ChannelRepository and ChannelRepository:find(params.name)
    local dvb_obj = DvbRepository and DvbRepository:find(params.name)

    if ch_obj then
        return HttpHelpers.success(server, client, {
            name = params.name, exists = true, type = "channel", is_active = true, state = ch_obj._state,
            details = {
                display_name = ch_obj._display_name,
                monitor_type = ch_obj._config.monitor_type
            }
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
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
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

--- Очистка неактивных ресурсов
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
function RoutesUtils.cleanup(server, client, request)
    local cleaned_count = 0
    local TablePool = ModuleManager.get_module("table_pool")

    -- 1. Очистка пулов таблиц
    if TablePool and TablePool.drain_all then
        TablePool.drain_all()
        cleaned_count = cleaned_count + 1
    end

    -- 2. Очистка кэша логов для неактивных компонентов
    if Logger and Logger.clear_component_buffer then
        -- TODO: Реализовать логику обхода всех компонентов и удаления тех,
        -- которых нет в репозиториях.
        local _ = Logger -- dummy use to avoid empty branch warning if needed
        Logger.debug(COMPONENT_NAME, "Очистка кэша логов (не реализовано)")
    end

    -- 3. Принудительный вызов GC
    collectgarbage("collect")
    collectgarbage("collect")

    return HttpHelpers.success(server, client, {
        message = "Системная очистка выполнена",
        cleaned_count = cleaned_count,
        lua_mem_kb = collectgarbage("count")
    })
end

--- Возвращает информацию об API
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
function RoutesUtils.get_api_info(server, client, request)
    return HttpHelpers.success(server, client, {
        api_version = "1.2.0",
        library_version = "2.4.0",
        supported_methods = {"GET", "POST", "PATCH", "DELETE"},
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

--- Возвращает HTML-страницу с документацией API
--- @param server table Объект сервера
--- @param client table Объект клиента
--- @param request table Объект запроса
--- @return boolean Всегда true
function RoutesUtils.get_api_docs(server, client, request)
    local html = [[
<!DOCTYPE html>
<html lang="ru">
<head>
    <meta charset="UTF-8">
    <title>Astra Monitor API Documentation</title>
    <style>
        body { font-family: sans-serif; line-height: 1.6; color: #333; max-width: 900px; margin: 0 auto; padding: 20px;
               background: #f4f4f9; }
        h1 { color: #2c3e50; border-bottom: 2px solid #2c3e50; padding-bottom: 10px; }
        h2 { color: #2980b9; margin-top: 30px; border-left: 5px solid #2980b9; padding-left: 10px; }
        .endpoint { background: #fff; padding: 15px; margin-bottom: 10px; border-radius: 5px;
                    box-shadow: 0 2px 5px rgba(0,0,0,0.1); }
        .method { font-weight: bold; color: #fff; padding: 3px 8px; border-radius: 3px; margin-right: 10px;
                  display: inline-block; min-width: 60px; text-align: center; }
        .GET { background: #2ecc71; }
        .POST { background: #f1c40f; }
        .PATCH { background: #3498db; }
        .DELETE { background: #e74c3c; }
        .path { font-family: monospace; font-size: 1.1em; font-weight: bold; }
        .desc { margin-top: 5px; color: #666; }
        code { background: #eee; padding: 2px 5px; border-radius: 3px; font-family: monospace; }
    </style>
</head>
<body>
    <h1>Astra Monitor API v1.2.0</h1>
    <p>Интерфейс управления системой мониторинга Cesbo Astra.</p>

    <h2>Система и Управление</h2>
    <div class="endpoint"><span class="method GET">GET</span> <span class="path">/api/system/health</span>
        <div class="desc">Состояние сервера и ресурсы</div></div>
    <div class="endpoint"><span class="method POST">POST</span> <span class="path">/api/system/watchdog</span>
        <div class="desc">Вкл/Выкл Watchdog (параметры: <code>enabled</code>, <code>repo</code>)</div></div>
    <div class="endpoint"><span class="method POST">POST</span> <span class="path">/api/system/auto-recover</span>
        <div class="desc">Вкл/Выкл Auto-recover (параметры: <code>enabled</code>, <code>repo</code>)</div></div>
    <div class="endpoint"><span class="method POST">POST</span> <span class="path">/api/system/maintenance/run</span>
        <div class="desc">Ручной запуск цикла восстановления</div></div>
    <div class="endpoint"><span class="method PATCH">PATCH</span> <span class="path">/api/system/config</span>
        <div class="desc">Обновление настроек в рантайме</div></div>

    <h2>DVB Адаптеры</h2>
    <div class="endpoint"><span class="method GET">GET</span> <span class="path">/api/dvb/adapters</span>
        <div class="desc">Список всех адаптеров</div></div>
    <div class="endpoint"><span class="method POST">POST</span> <span class="path">/api/dvb/adapters/scan</span>
        <div class="desc">Сканирование транспондера (параметры: <code>name</code>, <code>timeout</code>)</div></div>
    <div class="endpoint"><span class="method GET">GET</span> <span class="path">/api/dvb/adapters/data</span>
        <div class="desc">Метрики сигнала (параметр: <code>name</code>)</div></div>

    <h2>Мониторы и Каналы</h2>
    <div class="endpoint"><span class="method GET">GET</span> <span class="path">/api/monitors</span>
        <div class="desc">Список активных мониторов</div></div>
    <div class="endpoint"><span class="method GET">GET</span> <span class="path">/api/monitors/data</span>
        <div class="desc">Текущие данные монитора (параметр: <code>name</code>)</div></div>
    <div class="endpoint"><span class="method GET">GET</span> <span class="path">/api/utils/monitors/errors</span>
        <div class="desc">История ошибок и логи (параметр: <code>name</code>)</div></div>

    <h2>Утилиты</h2>
    <div class="endpoint"><span class="method POST">POST</span> <span class="path">/api/utils/cleanup</span>
        <div class="desc">Очистка памяти и пулов</div></div>
</body>
</html>
    ]]
    server:send(client, {
        code = 200,
        content = html,
        headers = { "Content-Type: text/html; charset=UTF-8" }
    })
    return true
end

return RoutesUtils
