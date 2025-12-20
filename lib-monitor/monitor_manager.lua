-- ===========================================================================
-- MonitorManager Class
-- Фасад для управления ChannelMonitorManager и DvbMonitorManager.
-- Предоставляет унифицированный интерфейс для работы с обоими типами мониторов.
-- ===========================================================================

local type      = type
local pairs     = pairs
local table_insert = table.insert

local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local ChannelMonitorManager = require "dispatcher.channel_monitor_manager"
local DvbMonitorManager = require "dispatcher.dvb_monitor_manager"

local COMPONENT_NAME = "MonitorManager"

local MonitorManager = {}
MonitorManager.__index = MonitorManager

--- Создает новый экземпляр MonitorManager.
-- Инициализирует внутренние менеджеры для каналов и DVB-тюнеров.
-- @return MonitorManager Новый объект MonitorManager.
function MonitorManager:new()
    local self = setmetatable({}, MonitorManager)
    self.channel_manager = ChannelMonitorManager:new()
    self.dvb_manager = DvbMonitorManager:new()
    log_info(COMPONENT_NAME, "MonitorManager initialized.")
    return self
end

--- Получает объект монитора по его имени.
-- Ищет монитор сначала в ChannelMonitorManager, затем в DvbMonitorManager.
-- @param string name Уникальное имя монитора.
-- @return table Объект монитора, если найден; `nil` и сообщение об ошибке, если монитор не существует или имя невалидно.
function MonitorManager:get_monitor(name)
    if not name or type(name) ~= "string" then
        local error_msg = "Invalid name: expected string, got " .. type(name) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local channel_monitor, channel_err = self.channel_manager:get_monitor(name)
    if channel_monitor then
        return channel_monitor, nil
    end

    local dvb_monitor, dvb_err = self.dvb_manager:get_monitor(name)
    if dvb_monitor then
        return dvb_monitor, nil
    end
    
    local error_msg = "Monitor '" .. name .. "' not found. Channel manager error: " .. (channel_err or "none") .. ". DVB manager error: " .. (dvb_err or "none") .. "."
    log_error(COMPONENT_NAME, error_msg)
    return nil, error_msg
end

--- Удаляет монитор по его имени.
-- Пытается удалить монитор сначала из ChannelMonitorManager, затем из DvbMonitorManager.
-- @param string name Уникальное имя монитора.
-- @return boolean true, если монитор успешно удален; `nil` и сообщение об ошибке в случае ошибки.
function MonitorManager:remove_monitor(name)
    if not name or type(name) ~= "string" then
        local error_msg = "Invalid name: expected string, got " .. type(name) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local success_channel, err_channel = self.channel_manager:remove_monitor(name)
    if success_channel then
        log_info(COMPONENT_NAME, "Monitor '%s' removed from ChannelMonitorManager.", name)
        return true, nil
    end

    local success_dvb, err_dvb = self.dvb_manager:remove_monitor(name)
    if success_dvb then
        log_info(COMPONENT_NAME, "Monitor '%s' removed from DvbMonitorManager.", name)
        return true, nil
    end

    local error_msg = "Failed to remove monitor '" .. name .. "'. Channel manager error: " .. (err_channel or "none") .. ". DVB manager error: " .. (err_dvb or "none") .. "."
    log_error(COMPONENT_NAME, error_msg)
    return nil, error_msg
end

--- Обновляет параметры монитора по его имени.
-- Пытается обновить параметры монитора сначала в ChannelMonitorManager, затем в DvbMonitorManager.
-- @param string name Уникальное имя монитора.
-- @param table params Таблица с новыми параметрами.
-- @return boolean true, если параметры успешно обновлены; `nil` и сообщение об ошибке в случае ошибки.
function MonitorManager:update_monitor_parameters(name, params)
    if not name or type(name) ~= "string" then
        local error_msg = "Invalid name: expected string, got " .. type(name) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not params or type(params) ~= "table" then
        local error_msg = "Invalid parameters for '" .. name .. "': expected table, got " .. type(params) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local success_channel, err_channel = self.channel_manager:update_monitor_parameters(name, params)
    if success_channel then
        log_info(COMPONENT_NAME, "Parameters updated for channel monitor '%s'.", name)
        return true, nil
    end

    local success_dvb, err_dvb = self.dvb_manager:update_monitor_parameters(name, params)
    if success_dvb then
        log_info(COMPONENT_NAME, "Parameters updated for DVB monitor '%s'.", name)
        return true, nil
    end

    local error_msg = "Failed to update parameters for monitor '" .. name .. "'. Channel manager error: " .. (err_channel or "none") .. ". DVB manager error: " .. (err_dvb or "none") .. "."
    log_error(COMPONENT_NAME, error_msg)
    return nil, error_msg
end

--- Возвращает таблицу всех активных мониторов (каналов и DVB-тюнеров).
-- @return table Таблица, содержащая все объекты мониторов.
function MonitorManager:get_all_monitors()
    local all_monitors = {}
    for name, monitor_obj in pairs(self.channel_manager:get_all_monitors()) do
        all_monitors[name] = monitor_obj
    end
    for name, monitor_obj in pairs(self.dvb_manager:get_all_monitors()) do
        all_monitors[name] = monitor_obj
    end
    return all_monitors
end

return MonitorManager
