-- ===========================================================================
-- MonitorManager Class
-- ===========================================================================

local type = type
-- local table_remove = table.remove -- Не используется
local Logger = require "utils.logger" -- Импортируем новый модуль логирования
local log_info = Logger.info
local log_error = Logger.error

local COMPONENT_NAME = "MonitorManager"

local MonitorManager = {}
MonitorManager.__index = MonitorManager

--- Конструктор для MonitorManager.
function MonitorManager:new()
    local self = setmetatable({}, MonitorManager)
    self.monitors = {} -- Таблица для хранения мониторов по имени
    return self
end

--- Добавляет монитор в менеджер.
-- @param string name Имя монитора.
-- @param table monitor_obj Объект монитора (DvbTunerMonitor или ChannelMonitor).
-- @return boolean true, если монитор успешно добавлен, иначе false.
function MonitorManager:add_monitor(name, monitor_obj)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got " .. type(name) .. ".")
        return false
    end
    if not monitor_obj or type(monitor_obj) ~= "table" then
        log_error(COMPONENT_NAME, "Invalid monitor object for '" .. name .. "': expected table, got " .. type(monitor_obj) .. ".")
        return false
    end
    if self.monitors[name] then
        log_error(COMPONENT_NAME, "Monitor with name '" .. name .. "' already exists. Cannot add duplicate.")
        return false
    end
    self.monitors[name] = monitor_obj
    log_info(COMPONENT_NAME, "Monitor '" .. name .. "' added successfully.")
    return true
end

--- Получает монитор по имени.
-- @param string name Имя монитора.
-- @return table Объект монитора, если найден, иначе nil.
function MonitorManager:get_monitor(name)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got " .. type(name) .. ".")
        return nil
    end
    return self.monitors[name]
end

--- Удаляет монитор по имени.
-- @param string name Имя монитора.
-- @return boolean true, если монитор успешно удален, иначе false.
function MonitorManager:remove_monitor(name)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got " .. type(name) .. ".")
        return false
    end
    local monitor_obj = self.monitors[name]
    if not monitor_obj then
        log_error(COMPONENT_NAME, "Monitor with name '" .. name .. "' not found. Cannot remove.")
        return false
    end
    if monitor_obj.kill and type(monitor_obj.kill) == "function" then
        monitor_obj:kill() -- Вызываем метод kill у самого монитора
        log_info(COMPONENT_NAME, "Called kill() on monitor '" .. name .. "'.")
    else
        log_info(COMPONENT_NAME, "Monitor '" .. name .. "' does not have a kill() method.")
    end
    self.monitors[name] = nil
    log_info(COMPONENT_NAME, "Monitor '" .. name .. "' removed successfully.")
    return true
end

--- Получает список всех мониторов.
-- @return table Таблица со всеми объектами мониторов.
function MonitorManager:get_all_monitors()
    return self.monitors
end

--- Обновляет параметры монитора по имени.
-- @param string name Имя монитора.
-- @param table params Таблица с новыми параметрами.
-- @return boolean true, если параметры успешно обновлены, иначе false.
function MonitorManager:update_monitor_parameters(name, params)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got " .. type(name) .. ".")
        return false
    end
    if not params or type(params) ~= "table" then
        log_error(COMPONENT_NAME, "Invalid parameters for '" .. name .. "': expected table, got " .. type(params) .. ".")
        return false
    end

    local monitor_obj = self:get_monitor(name)
    if not monitor_obj then
        log_error(COMPONENT_NAME, "Monitor '" .. name .. "' not found. Cannot update parameters.")
        return false
    end
    if monitor_obj.update_parameters and type(monitor_obj.update_parameters) == "function" then
        local success, err = pcall(monitor_obj.update_parameters, monitor_obj, params)
        if success then
            log_info(COMPONENT_NAME, "Parameters updated successfully for monitor '" .. name .. "'.")
            return true
        else
            log_error(COMPONENT_NAME, "Error updating parameters for monitor '" .. name .. "': " .. tostring(err))
            return false
        end
    else
        log_error(COMPONENT_NAME, "Monitor '" .. name .. "' does not support update_parameters method.")
        return false
    end
end

return MonitorManager
