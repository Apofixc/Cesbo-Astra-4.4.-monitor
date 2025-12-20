-- ===========================================================================
-- Оптимизации: Кэширование функций
-- ===========================================================================

local type = type
local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local COMPONENT_NAME = "Adapter"

local DvbTunerMonitor = require "adapters.dvb_tuner"
local DvbMonitorManager = require "dispatcher.dvb_monitor_manager"

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

local dvb_monitor_manager = DvbMonitorManager:new()

--- Возвращает список всех активных DVB-мониторов.
-- @return table dvb_monitors Таблица со всеми объектами DVB-мониторов.
function get_all_dvb_monitors()
    log_info(COMPONENT_NAME, "Retrieving all DVB monitors.")
    return dvb_monitor_manager:get_all_monitors()
end

--- Инициализирует и запускает мониторинг DVB-тюнера.
-- @param table conf Таблица конфигурации для DVB-тюнера.
-- @return userdata instance Экземпляр DVB-тюнера, если инициализация прошла успешно, иначе nil.
function dvb_tuner_monitor(conf)
    log_info(COMPONENT_NAME, "Attempting to create and register DVB monitor '%s'.", conf.name_adapter)
    return dvb_monitor_manager:create_and_register_dvb_monitor(conf)
end

--- Находит конфигурацию DVB-тюнера по имени адаптера.
-- @param string name_adapter Имя адаптера.
-- @return userdata instance Экземпляр DVB-тюнера, если найден, иначе nil.
function find_dvb_conf(name_adapter)
    if not name_adapter or type(name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "Invalid name_adapter: expected string, got %s.", type(name_adapter))
        return nil
    end
    local monitor = dvb_monitor_manager:get_monitor(name_adapter)
    if monitor then
        log_info(COMPONENT_NAME, "Found DVB configuration for adapter '%s'.", name_adapter)
        return monitor.instance
    end
    log_info(COMPONENT_NAME, "DVB configuration for adapter '%s' not found.", name_adapter)
    return nil
end

--- Обновляет параметры мониторинга DVB-тюнера.
-- @param string name_adapter Имя адаптера, параметры которого нужно обновить.
-- @param table params Таблица с новыми параметрами.
-- @return boolean true, если параметры успешно обновлены, иначе nil.
function update_dvb_monitor_parameters(name_adapter, params)
    if not name_adapter or type(name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "Invalid name_adapter: expected string, got %s.", type(name_adapter))
        return nil
    end
    if not params or type(params) ~= 'table' then
        log_error(COMPONENT_NAME, "Invalid parameters for '%s': expected table, got %s.", name_adapter, type(params))
        return nil
    end

    log_info(COMPONENT_NAME, "Attempting to update parameters for DVB monitor '%s'.", name_adapter)
    return dvb_monitor_manager:update_monitor_parameters(name_adapter, params)
end
