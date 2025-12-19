-- ===========================================================================
-- MonitorManager Class
-- ===========================================================================

local type = type
local log_info = log.info
local log_error = log.error
local table_remove = table.remove

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
    if not name or type(name) ~= "string" or not monitor_obj then
        log_error("[MonitorManager:add_monitor] Invalid name or monitor object.")
        return false
    end
    if self.monitors[name] then
        log_error("[MonitorManager:add_monitor] Monitor with name '" .. name .. "' already exists.")
        return false
    end
    self.monitors[name] = monitor_obj
    log_info("[MonitorManager:add_monitor] Monitor '" .. name .. "' added.")
    return true
end

--- Получает монитор по имени.
-- @param string name Имя монитора.
-- @return table Объект монитора, если найден, иначе nil.
function MonitorManager:get_monitor(name)
    if not name or type(name) ~= "string" then
        log_error("[MonitorManager:get_monitor] Invalid name.")
        return nil
    end
    return self.monitors[name]
end

--- Удаляет монитор по имени.
-- @param string name Имя монитора.
-- @return boolean true, если монитор успешно удален, иначе false.
function MonitorManager:remove_monitor(name)
    if not name or type(name) ~= "string" then
        log_error("[MonitorManager:remove_monitor] Invalid name.")
        return false
    end
    if not self.monitors[name] then
        log_error("[MonitorManager:remove_monitor] Monitor with name '" .. name .. "' not found.")
        return false
    end
    self.monitors[name]:kill() -- Вызываем метод kill у самого монитора
    self.monitors[name] = nil
    log_info("[MonitorManager:remove_monitor] Monitor '" .. name .. "' removed.")
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
    local monitor_obj = self:get_monitor(name)
    if monitor_obj and monitor_obj.update_parameters then
        return monitor_obj:update_parameters(params)
    else
        log_error("[MonitorManager:update_monitor_parameters] Monitor '" .. name .. "' not found or does not support update_parameters.")
        return false
    end
end

return MonitorManager
