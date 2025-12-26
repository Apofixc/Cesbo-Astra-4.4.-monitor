-- ===========================================================================
-- Модуль `adapters.adapter`
--
-- Этот модуль предоставляет интерфейс для управления DVB-тюнерами и их мониторингом.
-- Он использует `DvbMonitorManager` для создания, регистрации, поиска и обновления
-- параметров DVB-мониторов.
--
-- Основные функции включают:
-- - Получение списка всех активных DVB-мониторов.
-- - Инициализацию и запуск мониторинга для конкретного DVB-тюнера.
-- - Поиск конфигурации DVB-тюнера по имени адаптера.
-- - Обновление параметров мониторинга DVB-тюнера.
-- ===========================================================================

local type        = type
local Logger      = require "../utils/logger"
local log_info    = Logger.info
local log_error   = Logger.error

local COMPONENT_NAME = "Adapter"

local DvbTunerMonitor   = require "./dvb_tuner"
local DvbMonitorDispatcher = require "../../src/dispatchers/dvb_monitor_dispatcher"

local dvb_monitor_manager = DvbMonitorDispatcher:new()

--- Возвращает список всех активных DVB-мониторов.
-- Эта функция запрашивает у `DvbMonitorManager` список всех зарегистрированных
-- и активных DVB-мониторов.
-- @return table dvb_monitors Таблица со всеми объектами DVB-мониторов.
function get_all_dvb_monitors()
    log_info(COMPONENT_NAME, "Retrieving all DVB monitors.")
    return dvb_monitor_manager:get_all_monitors()
end

--- Инициализирует и запускает мониторинг DVB-тюнера.
-- Создает новый DVB-монитор на основе предоставленной конфигурации и регистрирует его
-- в `DvbMonitorManager`.
-- @param table conf Таблица конфигурации для DVB-тюнера. Ожидается поле `name_adapter` (string).
-- @return userdata instance Экземпляр DVB-тюнера, если инициализация прошла успешно, иначе `nil` и сообщение об ошибке.
function dvb_tuner_monitor(conf)
    if not conf or type(conf) ~= 'table' then
        local error_msg = "Invalid configuration provided. Expected table, got " .. type(conf) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not conf.name_adapter or type(conf.name_adapter) ~= 'string' then
        local error_msg = "Configuration missing 'name_adapter' or it's not a string."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    log_info(COMPONENT_NAME, "Attempting to create and register DVB monitor '%s'.", conf.name_adapter)
    return dvb_monitor_manager:create_and_register_dvb_monitor(conf)
end

--- Находит конфигурацию DVB-тюнера по имени адаптера.
-- Ищет зарегистрированный DVB-монитор по его имени адаптера.
-- @param string name_adapter Имя адаптера, по которому осуществляется поиск.
-- @return userdata instance Экземпляр DVB-тюнера, если найден, иначе `nil` и сообщение об ошибке.
function find_dvb_conf(name_adapter)
    if not name_adapter or type(name_adapter) ~= 'string' then
        local error_msg = "Invalid name_adapter: expected string, got " .. type(name_adapter) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    local monitor = dvb_monitor_manager:get_monitor(name_adapter)
    if monitor then
        return monitor.instance, nil
    end
    local error_msg = "DVB configuration for adapter '" .. name_adapter .. "' not found."
    log_info(COMPONENT_NAME, error_msg) -- Changed to log_info as it's not necessarily an error
    return nil, error_msg
end

--- Обновляет параметры мониторинга DVB-тюнера.
-- Обновляет параметры существующего DVB-монитора, идентифицируемого по имени адаптера.
-- @param string name_adapter Имя адаптера, параметры которого нужно обновить.
-- @param table params Таблица с новыми параметрами для DVB-монитора.
-- @return boolean true, если параметры успешно обновлены, иначе `nil` и сообщение об ошибке.
function update_dvb_monitor_parameters(name_adapter, params)
    if not name_adapter or type(name_adapter) ~= 'string' then
        local error_msg = "Invalid name_adapter: expected string, got " .. type(name_adapter) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not params or type(params) ~= 'table' then
        local error_msg = "Invalid parameters for '" .. name_adapter .. "': expected table, got " .. type(params) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    log_info(COMPONENT_NAME, "Attempting to update parameters for DVB monitor '%s'.", name_adapter)
    local success, err = dvb_monitor_manager:update_monitor_parameters(name_adapter, params)
    if success then
        log_info(COMPONENT_NAME, "Parameters updated successfully for DVB monitor: %s", name_adapter)
    else
        log_error(COMPONENT_NAME, "Failed to update parameters for DVB monitor: %s. Error: %s", name_adapter, err or "unknown error")
    end
    return success, err
end
