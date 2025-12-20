-- ===========================================================================
-- DvbMonitorManager Class
-- Управляет жизненным циклом и состоянием DVB-тюнер мониторов.
-- ===========================================================================

local type        = type
local Logger      = require "utils.logger"
local log_info    = Logger.info
local log_error   = Logger.error

local DvbTunerMonitor = require "adapters.dvb_tuner"
local MonitorConfig   = require "config.monitor_config"
local Utils           = require "utils.utils" -- Добавляем require для utils.utils
local validate_monitor_name = Utils.validate_monitor_name

local COMPONENT_NAME = "DvbMonitorManager"

local DvbMonitorManager = {}
DvbMonitorManager.__index = DvbMonitorManager

--- Создает новый экземпляр DvbMonitorManager.
-- Инициализирует пустую таблицу для хранения объектов DVB-мониторов.
-- @return DvbMonitorManager Новый объект DvbMonitorManager.
function DvbMonitorManager:new()
    local self = setmetatable({}, DvbMonitorManager)
    self.monitors = {} -- Таблица для хранения DVB-мониторов по их уникальному имени
    return self
end

--- Добавляет уже созданный и запущенный объект DVB-монитора в менеджер.
-- @param string name Уникальное имя монитора.
-- @param table monitor_obj Объект DVB-монитора, который должен быть таблицей.
-- @return boolean true, если монитор успешно добавлен; `nil` и сообщение об ошибке в случае ошибки.
function DvbMonitorManager:add_monitor(name, monitor_obj)
    local is_name_valid, name_err = validate_monitor_name(name)
    if not is_name_valid then
        return nil, name_err
    end
    if not monitor_obj or type(monitor_obj) ~= "table" then
        local error_msg = "Invalid monitor object for '" .. name .. "': expected table, got " .. type(monitor_obj) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if self.monitors[name] then
        local error_msg = "Monitor with name '" .. name .. "' already exists. Cannot add duplicate."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if #self.monitors >= MonitorConfig.DvbMonitorLimit then
        local error_msg = "DVB Monitor list overflow. Cannot create more than " .. MonitorConfig.DvbMonitorLimit .. " monitors."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    self.monitors[name] = monitor_obj
    log_info(COMPONENT_NAME, "DVB Monitor '%s' added successfully.", name)
    return true, nil
end

--- Создает, инициализирует и регистрирует новый DVB-тюнер монитор.
-- @param table conf Таблица конфигурации для DVB-тюнера.
-- @return userdata instance Экземпляр DVB-тюнера, если успешно создан и зарегистрирован, иначе `nil` и сообщение об ошибке.
function DvbMonitorManager:create_and_register_dvb_monitor(conf)
    if not conf or type(conf) ~= 'table' then
        local error_msg = "Invalid configuration table. Expected table, got " .. type(conf) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not conf.name_adapter or type(conf.name_adapter) ~= 'string' then
        local error_msg = "conf.name_adapter is required and must be a string."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local existing_monitor, get_err = self:get_monitor(conf.name_adapter)
    if existing_monitor then
        local error_msg = "Monitor with name '" .. conf.name_adapter .. "' already exists."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if get_err then
        log_error(COMPONENT_NAME, "Error checking for existing monitor '%s': %s", conf.name_adapter, get_err)
        return nil, get_err
    end

    local monitor = DvbTunerMonitor:new(conf)
    local instance, start_err = monitor:start()

    if instance then
        local success, add_err = self:add_monitor(conf.name_adapter, monitor)
        if success then
            log_info(COMPONENT_NAME, "DVB Tuner monitor '%s' started and added successfully.", conf.name_adapter)
            return instance, nil
        else
            log_error(COMPONENT_NAME, "Failed to add DVB Tuner monitor '%s' to manager: %s", conf.name_adapter, add_err or "unknown error")
            return nil, add_err or "Failed to add monitor to manager"
        end
    else
        local error_msg = "Failed to start DVB Tuner monitor '" .. conf.name_adapter .. "'. Error: " .. (start_err or "unknown")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
end

--- Получает объект DVB-монитора по его имени.
-- @param string name Уникальное имя монитора.
-- @return table Объект монитора, если найден; `nil` и сообщение об ошибке, если монитор с таким именем не существует или имя невалидно.
function DvbMonitorManager:get_monitor(name)
    local is_name_valid, name_err = validate_monitor_name(name)
    if not is_name_valid then
        return nil, name_err
    end
    return self.monitors[name], nil
end

--- Удаляет DVB-монитор из менеджера по его имени.
-- Если монитор имеет метод `kill()`, он будет вызван перед удалением.
-- @param string name Уникальное имя монитора.
-- @return boolean true, если монитор успешно удален; `nil` и сообщение об ошибке в случае ошибки.
function DvbMonitorManager:remove_monitor(name)
    local is_name_valid, name_err = validate_monitor_name(name)
    if not is_name_valid then
        return nil, name_err
    end
    local monitor_obj, get_err = self:get_monitor(name)
    if not monitor_obj then
        local error_msg = "Monitor with name '" .. name .. "' not found. Cannot remove. Error: " .. (get_err or "unknown")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if monitor_obj.kill and type(monitor_obj.kill) == "function" then
        monitor_obj:kill() -- Вызываем метод kill у самого монитора
        log_info(COMPONENT_NAME, "Called kill() on DVB monitor '%s'.", name)
    else
        log_info(COMPONENT_NAME, "DVB Monitor '%s' does not have a kill() method.", name)
    end
    self.monitors[name] = nil
    log_info(COMPONENT_NAME, "DVB Monitor '%s' removed successfully.", name)
    return true, nil
end

--- Возвращает таблицу всех активных DVB-мониторов, управляемых менеджером.
-- Ключами таблицы являются имена мониторов, значениями - соответствующие объекты мониторов.
-- @return table Таблица, содержащая все объекты DVB-мониторов.
function DvbMonitorManager:get_all_monitors()
    return self.monitors
end

--- Обновляет параметры существующего DVB-монитора по его имени.
-- Если монитор поддерживает метод `update_parameters`, он будет вызван с новыми параметрами.
-- @param string name Уникальное имя монитора.
-- @param table params Таблица, содержащая новые параметры для обновления.
-- @return boolean true, если параметры успешно обновлены; `nil` и сообщение об ошибке в случае ошибки.
function DvbMonitorManager:update_monitor_parameters(name, params)
    local is_name_valid, name_err = validate_monitor_name(name)
    if not is_name_valid then
        return nil, name_err
    end
    if not params or type(params) ~= "table" then
        local error_msg = "Invalid parameters for '" .. name .. "': expected table, got " .. type(params) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local monitor_obj, get_err = self:get_monitor(name)
    if not monitor_obj then
        local error_msg = "DVB Monitor '" .. name .. "' not found. Cannot update parameters. Error: " .. (get_err or "unknown")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if monitor_obj.update_parameters and type(monitor_obj.update_parameters) == "function" then
        local success, err = pcall(monitor_obj.update_parameters, monitor_obj, params)
        if success then
            log_info(COMPONENT_NAME, "Parameters updated successfully for DVB monitor '%s'.", name)
            return true, nil
        else
            local error_msg = "Error updating parameters for DVB monitor '" .. name .. "': " .. tostring(err)
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
    else
        local error_msg = "DVB Monitor '" .. name .. "' does not support update_parameters method."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
end

return DvbMonitorManager
