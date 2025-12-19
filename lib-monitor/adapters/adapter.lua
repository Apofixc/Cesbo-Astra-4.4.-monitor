-- ===========================================================================
-- Оптимизации: Кэширование функций
-- ===========================================================================

local type = type
local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local COMPONENT_NAME = "Adapter"

local DvbTunerMonitor = require "adapters.dvb_tuner"
local MonitorManager = require "monitor_manager"

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

local monitor_manager = MonitorManager:new()

--- Возвращает список всех активных DVB-мониторов.
-- @return table dvb_monitors Таблица со всеми объектами DVB-мониторов.
function get_all_dvb_monitors()
    log_info(COMPONENT_NAME, "Retrieving all DVB monitors.")
    return monitor_manager:get_all_monitors()
end

--- Инициализирует и запускает мониторинг DVB-тюнера.
-- @param table conf Таблица конфигурации для DVB-тюнера.
-- @return userdata instance Экземпляр DVB-тюнера, если инициализация прошла успешно, иначе nil.
function dvb_tuner_monitor(conf)
    if not conf or type(conf) ~= 'table' then
        log_error(COMPONENT_NAME, "Invalid configuration table.")
        return nil
    end
    if not conf.name_adapter or type(conf.name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "conf.name_adapter is required and must be a string.")
        return nil
    end

    if monitor_manager:get_monitor(conf.name_adapter) then
        log_error(COMPONENT_NAME, "Monitor with name '" .. conf.name_adapter .. "' already exists.")
        return nil
    end

    local monitor = DvbTunerMonitor:new(conf)
    local instance = monitor:start()

    if instance then
        monitor_manager:add_monitor(conf.name_adapter, monitor)
        log_info(COMPONENT_NAME, "DVB Tuner monitor '" .. conf.name_adapter .. "' started successfully.")
        return instance
    else
        log_error(COMPONENT_NAME, "Failed to start DVB Tuner monitor '" .. conf.name_adapter .. "'.")
        return nil
    end
end

--- Находит конфигурацию DVB-тюнера по имени адаптера.
-- @param string name_adapter Имя адаптера.
-- @return userdata instance Экземпляр DVB-тюнера, если найден, иначе nil.
function find_dvb_conf(name_adapter)
    if not name_adapter or type(name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "Invalid name_adapter: expected string, got " .. type(name_adapter) .. ".")
        return nil
    end
    local monitor = monitor_manager:get_monitor(name_adapter)
    if monitor then
        log_info(COMPONENT_NAME, "Found DVB configuration for adapter '" .. name_adapter .. "'.")
        return monitor.instance
    end
    log_info(COMPONENT_NAME, "DVB configuration for adapter '" .. name_adapter .. "' not found.")
    return nil
end

--- Обновляет параметры мониторинга DVB-тюнера.
-- @param string name_adapter Имя адаптера, параметры которого нужно обновить.
-- @param table params Таблица с новыми параметрами.
-- @return boolean true, если параметры успешно обновлены, иначе nil.
function update_dvb_monitor_parameters(name_adapter, params)
    if not name_adapter or type(name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "Invalid name_adapter: expected string, got " .. type(name_adapter) .. ".")
        return nil
    end
    if not params or type(params) ~= 'table' then
        log_error(COMPONENT_NAME, "Invalid parameters for '" .. name_adapter .. "': expected table, got " .. type(params) .. ".")
        return nil
    end

    log_info(COMPONENT_NAME, "Attempting to update parameters for DVB monitor '" .. name_adapter .. "'.")
    return monitor_manager:update_monitor_parameters(name_adapter, params)
end
