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
local ResourceMonitorManager = require "dispatcher.resource_monitor_manager"

local COMPONENT_NAME = "MonitorManager"

local MonitorManager = {}
MonitorManager.__index = MonitorManager

--- Создает новый экземпляр MonitorManager.
-- Инициализирует внутренние менеджеры для каналов, DVB-тюнеров и системных ресурсов.
-- @return MonitorManager Новый объект MonitorManager.
function MonitorManager:new()
    local self = setmetatable({}, MonitorManager)
    self.channel_manager = ChannelMonitorManager:new()
    self.dvb_manager = DvbMonitorManager:new()
    self.resource_manager = ResourceMonitorManager:new()
    log_info(COMPONENT_NAME, "MonitorManager initialized.")
    return self
end

--- Получает объект монитора по его имени.
-- Ищет монитор сначала в ChannelMonitorManager, затем в DvbMonitorManager, затем в ResourceMonitorManager.
-- @param string name Уникальное имя монитора.
-- @return table Объект монитора, если найден; `nil` и сообщение об ошибке, если монитор не существует или имя невалидно.
function MonitorManager:get_monitor(name)
    if not name or type(name) ~= "string" then
        local error_msg = "Invalid name: expected string, got " .. type(name) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local channel_monitor, channel_err = pcall(self.channel_manager.get_monitor, self.channel_manager, name)
    if channel_monitor and not channel_err then
        return channel_monitor, nil
    elseif channel_err and type(channel_err) == "string" then
        log_info(COMPONENT_NAME, "Channel manager failed to get monitor '%s': %s", name, channel_err)
    end

    local dvb_monitor, dvb_err = pcall(self.dvb_manager.get_monitor, self.dvb_manager, name)
    if dvb_monitor and not dvb_err then
        return dvb_monitor, nil
    elseif dvb_err and type(dvb_err) == "string" then
        log_info(COMPONENT_NAME, "DVB manager failed to get monitor '%s': %s", name, dvb_err)
    end

    local resource_monitor, resource_err = pcall(self.resource_manager.get_monitor, self.resource_manager, name)
    if resource_monitor and not resource_err then
        return resource_monitor, nil
    elseif resource_err and type(resource_err) == "string" then
        log_info(COMPONENT_NAME, "Resource manager failed to get monitor '%s': %s", name, resource_err)
    end
    
    local error_msg = string.format("Monitor '%s' not found in any manager. Channel manager status: %s. DVB manager status: %s. Resource manager status: %s.",
                                    name,
                                    (channel_monitor and "found" or (channel_err or "not found")),
                                    (dvb_monitor and "found" or (dvb_err or "not found")),
                                    (resource_monitor and "found" or (resource_err or "not found")))
    log_error(COMPONENT_NAME, error_msg)
    return nil, error_msg
end

--- Удаляет монитор по его имени.
-- Пытается удалить монитор сначала из ChannelMonitorManager, затем из DvbMonitorManager, затем из ResourceMonitorManager.
-- @param string name Уникальное имя монитора.
-- @return boolean true, если монитор успешно удален; `nil` и сообщение об ошибке в случае ошибки.
function MonitorManager:remove_monitor(name)
    if not name or type(name) ~= "string" then
        local error_msg = "Invalid name: expected string, got " .. type(name) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local success_channel, err_channel = pcall(self.channel_manager.remove_monitor, self.channel_manager, name)
    if success_channel and not err_channel then
        log_info(COMPONENT_NAME, "Monitor '%s' removed from ChannelMonitorManager.", name)
        return true, nil
    elseif err_channel and type(err_channel) == "string" then
        log_info(COMPONENT_NAME, "Channel manager failed to remove monitor '%s': %s", name, err_channel)
    end

    local success_dvb, err_dvb = pcall(self.dvb_manager.remove_monitor, self.dvb_manager, name)
    if success_dvb and not err_dvb then
        log_info(COMPONENT_NAME, "Monitor '%s' removed from DvbMonitorManager.", name)
        return true, nil
    elseif err_dvb and type(err_dvb) == "string" then
        log_info(COMPONENT_NAME, "DVB manager failed to remove monitor '%s': %s", name, err_dvb)
    end

    local success_resource, err_resource = pcall(self.resource_manager.remove_monitor, self.resource_manager, name)
    if success_resource and not err_resource then
        log_info(COMPONENT_NAME, "Monitor '%s' removed from ResourceMonitorManager.", name)
        return true, nil
    elseif err_resource and type(err_resource) == "string" then
        log_info(COMPONENT_NAME, "Resource manager failed to remove monitor '%s': %s", name, err_resource)
    end

    local error_msg = string.format("Failed to remove monitor '%s' from any manager. Channel manager status: %s. DVB manager status: %s. Resource manager status: %s.",
                                    name,
                                    (success_channel and "removed" or (err_channel or "not removed")),
                                    (success_dvb and "removed" or (err_dvb or "not removed")),
                                    (success_resource and "removed" or (err_resource or "not removed")))
    log_error(COMPONENT_NAME, error_msg)
    return nil, error_msg
end

--- Обновляет параметры монитора по его имени.
-- Пытается обновить параметры монитора сначала в ChannelMonitorManager, затем в DvbMonitorManager, затем в ResourceMonitorManager.
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

    local success_channel, err_channel = pcall(self.channel_manager.update_monitor_parameters, self.channel_manager, name, params)
    if success_channel and not err_channel then
        log_info(COMPONENT_NAME, "Parameters updated for channel monitor '%s'.", name)
        return true, nil
    elseif err_channel and type(err_channel) == "string" then
        log_info(COMPONENT_NAME, "Channel manager failed to update parameters for monitor '%s': %s", name, err_channel)
    end

    local success_dvb, err_dvb = pcall(self.dvb_manager.update_monitor_parameters, self.dvb_manager, name, params)
    if success_dvb and not err_dvb then
        log_info(COMPONENT_NAME, "Parameters updated for DVB monitor '%s'.", name)
        return true, nil
    elseif err_dvb and type(err_dvb) == "string" then
        log_info(COMPONENT_NAME, "DVB manager failed to update parameters for monitor '%s': %s", name, err_dvb)
    end

    local success_resource, err_resource = pcall(self.resource_manager.update_monitor_parameters, self.resource_manager, name, params)
    if success_resource and not err_resource then
        log_info(COMPONENT_NAME, "Parameters updated for resource monitor '%s'.", name)
        return true, nil
    elseif err_resource and type(err_resource) == "string" then
        log_info(COMPONENT_NAME, "Resource manager failed to update parameters for monitor '%s': %s", name, err_resource)
    end

    local error_msg = string.format("Failed to update parameters for monitor '%s' in any manager. Channel manager status: %s. DVB manager status: %s. Resource manager status: %s.",
                                    name,
                                    (success_channel and "updated" or (err_channel or "not updated")),
                                    (success_dvb and "updated" or (err_dvb or "not updated")),
                                    (success_resource and "updated" or (err_resource or "not updated")))
    log_error(COMPONENT_NAME, error_msg)
    return nil, error_msg
end

--- Возвращает итератор для всех активных мониторов (каналов, DVB-тюнеров и системных ресурсов).
-- Это позволяет перебирать мониторы без создания новой большой таблицы,
-- что может быть более эффективным для большого количества мониторов.
-- @return function Итератор, который возвращает `name, monitor_obj`.
function MonitorManager:get_all_monitors()
    local channel_iter, channel_state, channel_var = pairs(self.channel_manager:get_all_monitors())
    local dvb_iter, dvb_state, dvb_var = pairs(self.dvb_manager:get_all_monitors())
    local resource_iter, resource_state, resource_var = pairs(self.resource_manager:get_all_monitors())

    return function()
        local name, monitor_obj = channel_iter(channel_state, channel_var)
        if name then
            channel_var = name
            return name, monitor_obj
        else
            local name_dvb, monitor_obj_dvb = dvb_iter(dvb_state, dvb_var)
            if name_dvb then
                dvb_var = name_dvb
                return name_dvb, monitor_obj_dvb
            else
                local name_resource, monitor_obj_resource = resource_iter(resource_state, resource_var)
                if name_resource then
                    resource_var = name_resource
                    return name_resource, monitor_obj_resource
                else
                    return nil
                end
            end
        end
    end
end

return MonitorManager
