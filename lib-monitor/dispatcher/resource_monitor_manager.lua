-- ===========================================================================
-- ResourceMonitorManager Class
-- Менеджер для мониторинга системных ресурсов (CPU, RAM, Disk I/O, Network I/O).
-- ===========================================================================

local type      = type
local pairs     = pairs
local table_insert = table.insert

local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local ResourceAdapter = require "adapters.resource_adapter" -- Будет создан позже

local COMPONENT_NAME = "ResourceMonitorManager"

local ResourceMonitorManager = {}
ResourceMonitorManager.__index = ResourceMonitorManager

--- Создает новый экземпляр ResourceMonitorManager.
-- @return ResourceMonitorManager Новый объект ResourceMonitorManager.
function ResourceMonitorManager:new()
    local self = setmetatable({}, ResourceMonitorManager)
    self.monitors = {} -- Хранилище для ресурсных мониторов
    log_info(COMPONENT_NAME, "ResourceMonitorManager initialized.")
    return self
end

--- Добавляет новый ресурсный монитор.
-- @param string name Уникальное имя монитора.
-- @param table config Конфигурация монитора.
-- @return table Объект монитора, если успешно создан; `nil` и сообщение об ошибке в случае ошибки.
function ResourceMonitorManager:add_monitor(name, config)
    if not name or type(name) ~= "string" then
        local error_msg = "Invalid name: expected string, got " .. type(name) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if self.monitors[name] then
        local error_msg = string.format("Monitor '%s' already exists.", name)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local monitor, err = ResourceAdapter:new(name, config)
    if not monitor then
        log_error(COMPONENT_NAME, "Failed to create resource monitor '%s': %s", name, err)
        return nil, err
    end

    self.monitors[name] = monitor
    log_info(COMPONENT_NAME, "Resource monitor '%s' added.", name)
    return monitor
end

--- Получает объект монитора по его имени.
-- @param string name Уникальное имя монитора.
-- @return table Объект монитора, если найден; `nil` и сообщение об ошибке, если монитор не существует.
function ResourceMonitorManager:get_monitor(name)
    if not name or type(name) ~= "string" then
        local error_msg = "Invalid name: expected string, got " .. type(name) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local monitor = self.monitors[name]
    if not monitor then
        local error_msg = string.format("Resource monitor '%s' not found.", name)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    return monitor
end

--- Удаляет монитор по его имени.
-- @param string name Уникальное имя монитора.
-- @return boolean true, если монитор успешно удален; `nil` и сообщение об ошибке в случае ошибки.
function ResourceMonitorManager:remove_monitor(name)
    if not name or type(name) ~= "string" then
        local error_msg = "Invalid name: expected string, got " .. type(name) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    if not self.monitors[name] then
        local error_msg = string.format("Resource monitor '%s' not found.", name)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    self.monitors[name]:stop() -- Останавливаем монитор перед удалением
    self.monitors[name] = nil
    log_info(COMPONENT_NAME, "Resource monitor '%s' removed.", name)
    return true
end

--- Обновляет параметры монитора по его имени.
-- @param string name Уникальное имя монитора.
-- @param table params Таблица с новыми параметрами.
-- @return boolean true, если параметры успешно обновлены; `nil` и сообщение об ошибке в случае ошибки.
function ResourceMonitorManager:update_monitor_parameters(name, params)
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

    local monitor = self.monitors[name]
    if not monitor then
        local error_msg = string.format("Resource monitor '%s' not found.", name)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local success, err = monitor:update_parameters(params)
    if not success then
        log_error(COMPONENT_NAME, "Failed to update parameters for resource monitor '%s': %s", name, err)
        return nil, err
    end

    log_info(COMPONENT_NAME, "Parameters updated for resource monitor '%s'.", name)
    return true
end

--- Возвращает итератор для всех активных ресурсных мониторов.
-- @return function Итератор, который возвращает `name, monitor_obj`.
function ResourceMonitorManager:get_all_monitors()
    return pairs(self.monitors)
end

return ResourceMonitorManager
