--- @class DvbRoutes
local DvbRoutes = {}

-- 1. Стандартные Lua функции
local pairs = pairs
local table_insert = table.insert

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpHelpers = ModuleManager.get_module("http_helpers")
local Adapter = ModuleManager.get_module("adapter")
local DvbRepository = ModuleManager.get_module("dvb_repository")
local RoutesUtils = ModuleManager.get_module("routes_utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local dvbls = ModuleManager.get_global_dependency("dvbls")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbRoutes"

--- Возвращает список всех DVB адаптеров в системе
function DvbRoutes.get_adapters(server, client, request)
    local list = dvbls and dvbls() or {}
    local adapters = {}
    for _, data in pairs(list) do table_insert(adapters, data) end
    return HttpHelpers.success(server, client, adapters)
end

--- Возвращает список адаптеров, находящихся под мониторингом
function DvbRoutes.get_monitored_adapters(server, client, request)
    local active_adapters = DvbRepository and DvbRepository:get_all() or {}
    local list = {}
    for name in pairs(active_adapters) do list[name] = name end
    return HttpHelpers.success(server, client, list)
end

--- Запуск сканирования адаптеров
function DvbRoutes.scan_adapters(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, {
        name = { type = "string", required = true },
        timeout = { type = "number", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success = Adapter.scan_dvb(params.name, params.timeout, function(services)
        -- Мы не можем отправить ответ из callback-а асинхронно в Astra http_server напрямую,
        -- если соединение уже закрыто. Но в Astra http_server обработчик должен вернуть true/false.
        -- Однако, для сканирования, которое занимает время, обычно используют либо WebSocket,
        -- либо сохраняют результат в кэш объекта.
        -- В данном случае, так как scan_dvb использует планировщик, мы просто запускаем процесс.
        -- Для получения результата пользователю нужно будет вызвать GET /api/dvb/adapters/psi
        -- или мы можем добавить специальный статус.
    end)

    if not success then
        return HttpHelpers.error(server, client, 500, "Не удалось запустить сканирование")
    end

    return HttpHelpers.success(server, client, { message = "Сканирование запущено. Результаты будут доступны в PSI таблицах." })
end

--- Возвращает текущие метрики конкретного DVB адаптера
function DvbRoutes.get_adapter_data(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dvb_obj = DvbRepository and DvbRepository:find(params.name)
    if not dvb_obj then return HttpHelpers.error(server, client, 404, "Адаптер не найден") end

    if dvb_obj._json_cache then return HttpHelpers.send_raw_json(server, client, 200, dvb_obj._json_cache) end
    return HttpHelpers.success(server, client, dvb_obj:get_status_table())
end

--- Обновляет параметры мониторинга DVB адаптера
function DvbRoutes.update_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Adapter.update_dvb_monitor_parameters(params.name, params)
    if not success then
        return HttpHelpers.error(server, client, 500, result_err or "Не удалось обновить")
    end

    return HttpHelpers.success(server, client, { message = "Мониторинг адаптера обновлен" })
end

--- Останавливает мониторинг DVB адаптера
function DvbRoutes.stop_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, {
        name = { type = "string", required = true },
        force = { type = "boolean", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_or_err = Adapter.stop_dvb_monitor(params.name, params.force == true)
    if not success then
        return HttpHelpers.error(server, client, 500, result_or_err or "Не удалось остановить")
    end

    return HttpHelpers.success(server, client, { message = "Адаптер остановлен", config = result_or_err })
end

--- Возвращает PSI данные DVB адаптера
function DvbRoutes.get_adapter_psi(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, {
        name = { type = "string", required = true },
        table = { type = "string", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dvb_obj = DvbRepository and DvbRepository:find(params.name)
    if not dvb_obj then return HttpHelpers.error(server, client, 404, "Адаптер не найден") end

    local psi = dvb_obj:get_psi() or {}
    if params.table then
        local table_data = psi[params.table:upper()]
        if not table_data then return HttpHelpers.error(server, client, 404, "Таблица PSI не найдена") end
        return HttpHelpers.success(server, client, table_data)
    end

    psi.adapter_name = params.name
    return HttpHelpers.success(server, client, psi)
end

--- Запускает обновление PSI данных на адаптере
function DvbRoutes.update_adapter_psi(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dvb_obj = DvbRepository and DvbRepository:find(params.name)
    if not dvb_obj then return HttpHelpers.error(server, client, 404, "Адаптер не найден") end

    dvb_obj:psi_update()
    return HttpHelpers.success(server, client, { message = "Обновление PSI запущено" })
end

--- Настройка адаптера на частоту и запуск мониторинга
function DvbRoutes.tune_adapter(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(data, {
        name_adapter = { type = "string", required = true },
        tp = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_or_err = Adapter.dvb_tuner_monitor(data)
    if not success then
        return HttpHelpers.error(server, client, 500, result_or_err or "Не удалось настроить тюнер")
    end

    return HttpHelpers.success(server, client, { message = "Настройка адаптера запущена" })
end

--- Переключение транспондера
function DvbRoutes.switch_transponder(server, client, request)
    local data = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(data, {
        name = { type = "string", required = true },
        tp = { type = "string", required = true }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_or_err = Adapter.switch_transponder(data.name, data, data.reserve_input)
    if not success then
        return HttpHelpers.error(server, client, 500, result_or_err or "Не удалось переключить")
    end

    return HttpHelpers.success(server, client, { message = "Транспондер переключен", backup = result_or_err })
end

--- Приостановка мониторинга адаптера
function DvbRoutes.pause_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Adapter.pause_dvb_monitor(params.name)
    if not success then return false, result_err or "Не удалось приостановить" end

    return HttpHelpers.success(server, client, { message = "Мониторинг адаптера приостановлен" })
end

--- Возобновление мониторинга адаптера
function DvbRoutes.resume_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Adapter.resume_dvb_monitor(params.name)
    if not success then return false, result_err or "Не удалось возобновить" end

    return HttpHelpers.success(server, client, { message = "Мониторинг адаптера возобновлен" })
end

--- Перезапуск мониторинга адаптера
function DvbRoutes.restart_adapter(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, {
        name = { type = "string", required = true },
        force = { type = "boolean", required = false }
    })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local success, result_err = Adapter.restart_dvb_monitor(params.name, params, params.force == true)
    if not success then return false, result_err or "Не удалось перезапустить" end

    return HttpHelpers.success(server, client, { message = "Адаптер перезапущен" })
end

--- Возвращает список всех физических адаптеров
function DvbRoutes.get_hardware_all(server, client, request)
    local list = dvbls and dvbls() or {}
    return HttpHelpers.success(server, client, list)
end

--- Возвращает детальные флаги состояния DVB адаптера (has_signal, has_lock и т.д.)
function DvbRoutes.get_adapter_status_info(server, client, request)
    local params = HttpHelpers.get_params(request)
    local ok, err = RoutesUtils.validate_input(params, { name = { type = "string", required = true } })
    if not ok then return HttpHelpers.error(server, client, 400, err) end

    local dvb_obj = DvbRepository and DvbRepository:find(params.name)
    if not dvb_obj then return HttpHelpers.error(server, client, 404, "Адаптер не найден") end

    return HttpHelpers.success(server, client, dvb_obj:get_status_flags())
end

return DvbRoutes
