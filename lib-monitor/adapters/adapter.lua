-- ===========================================================================
-- Оптимизации: Кэширование функций
-- ===========================================================================

local type = type
local log_info = log.info
local log_error = log.error

local DvbTunerMonitor = require "adapters.dvb_tuner"
local MonitorManager = require "monitor_manager"

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

local monitor_manager = MonitorManager:new()

--- Возвращает текущую конфигурацию DVB-адаптеров.
-- @return table dvb_config Таблица с конфигурацией DVB-адаптеров.
function get_list_adapter()
    return monitor_manager:get_all_monitors()
end

--- Инициализирует и запускает мониторинг DVB-тюнера.
-- @param table conf Таблица конфигурации для DVB-тюнера.
-- @return userdata instance Экземпляр DVB-тюнера, если инициализация прошла успешно, иначе nil.
function dvb_tuner_monitor(conf)
    if not conf.name_adapter then
        log_error("[dvb_tuner] name is not found")
        return
    end

    if monitor_manager:get_monitor(conf.name_adapter) then
        log_error("[dvb_tuner] tuner is found")
        return
    end

    local monitor = DvbTunerMonitor:new(conf)
    local instance = monitor:start()

    if instance then
        monitor_manager:add_monitor(conf.name_adapter, monitor)
        return instance
    end
end

--- Находит конфигурацию DVB-тюнера по имени адаптера.
-- @param string name_adapter Имя адаптера.
-- @return userdata instance Экземпляр DVB-тюнера, если найден, иначе nil.
function find_dvb_conf(name_adapter)
    local monitor = monitor_manager:get_monitor(name_adapter)
    if monitor then
        return monitor.instance
    end
    return nil
end

--- Обновляет параметры мониторинга DVB-тюнера.
-- @param string name_adapter Имя адаптера, параметры которого нужно обновить.
-- @param table params Таблица с новыми параметрами.
-- @return boolean true, если параметры успешно обновлены, иначе nil.
function update_dvb_monitor_parameters(name_adapter, params)
    if not name_adapter or type(params) ~= 'table' then
        log_error("[update_dvb_monitor_parameters] name_adapter and params table are required")
        return nil
    end

    return monitor_manager:update_monitor_parameters(name_adapter, params)
end
