-- ===========================================================================
-- DvbMonitorManager Class
-- Управляет жизненным циклом и состоянием DVB-тюнер мониторов.
-- ===========================================================================

local type = type
local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local DvbTunerMonitor = require "adapters.dvb_tuner"
local MonitorConfig = require "config.monitor_config"

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
-- @return boolean true, если монитор успешно добавлен; false в случае ошибки.
function DvbMonitorManager:add_monitor(name, monitor_obj)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got %s.", type(name))
        return false
    end
    if not monitor_obj or type(monitor_obj) ~= "table" then
        log_error(COMPONENT_NAME, "Invalid monitor object for '%s': expected table, got %s.", name, type(monitor_obj))
        return false
    end
    if self.monitors[name] then
        log_error(COMPONENT_NAME, "Monitor with name '%s' already exists. Cannot add duplicate.", name)
        return false
    end
    if #self.monitors >= MonitorConfig.DvbMonitorLimit then -- Предполагаем, что есть DvbMonitorLimit
        log_error(COMPONENT_NAME, "DVB Monitor list overflow. Cannot create more than %d monitors.", MonitorConfig.DvbMonitorLimit)
        return false
    end

    self.monitors[name] = monitor_obj
    log_info(COMPONENT_NAME, "DVB Monitor '%s' added successfully.", name)
    return true
end

--- Создает, инициализирует и регистрирует новый DVB-тюнер монитор.
-- @param table conf Таблица конфигурации для DVB-тюнера.
-- @return userdata instance Экземпляр DVB-тюнера, если успешно создан и зарегистрирован, иначе nil.
function DvbMonitorManager:create_and_register_dvb_monitor(conf)
    if not conf or type(conf) ~= 'table' then
        log_error(COMPONENT_NAME, "Invalid configuration table.")
        return nil
    end
    if not conf.name_adapter or type(conf.name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "conf.name_adapter is required and must be a string.")
        return nil
    end

    if self:get_monitor(conf.name_adapter) then
        log_error(COMPONENT_NAME, "Monitor with name '%s' already exists.", conf.name_adapter)
        return nil
    end

    local monitor = DvbTunerMonitor:new(conf)
    local instance = monitor:start()

    if instance then
        self:add_monitor(conf.name_adapter, monitor)
        log_info(COMPONENT_NAME, "DVB Tuner monitor '%s' started successfully.", conf.name_adapter)
        return instance
    else
        log_error(COMPONENT_NAME, "Failed to start DVB Tuner monitor '%s'.", conf.name_adapter)
        return nil
    end
end

--- Получает объект DVB-монитора по его имени.
-- @param string name Уникальное имя монитора.
-- @return table Объект монитора, если найден; nil, если монитор с таким именем не существует или имя невалидно.
function DvbMonitorManager:get_monitor(name)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got %s.", type(name))
        return nil
    end
    return self.monitors[name]
end

--- Удаляет DVB-монитор из менеджера по его имени.
-- Если монитор имеет метод `kill()`, он будет вызван перед удалением.
-- @param string name Уникальное имя монитора.
-- @return boolean true, если монитор успешно удален; false в случае ошибки.
function DvbMonitorManager:remove_monitor(name)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got %s.", type(name))
        return false
    end
    local monitor_obj = self.monitors[name]
    if not monitor_obj then
        log_error(COMPONENT_NAME, "Monitor with name '%s' not found. Cannot remove.", name)
        return false
    end
    if monitor_obj.kill and type(monitor_obj.kill) == "function" then
        monitor_obj:kill() -- Вызываем метод kill у самого монитора
        log_info(COMPONENT_NAME, "Called kill() on DVB monitor '%s'.", name)
    else
        log_info(COMPONENT_NAME, "DVB Monitor '%s' does not have a kill() method.", name)
    end
    self.monitors[name] = nil
    log_info(COMPONENT_NAME, "DVB Monitor '%s' removed successfully.", name)
    return true
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
-- @return boolean true, если параметры успешно обновлены; false в случае ошибки.
function DvbMonitorManager:update_monitor_parameters(name, params)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got %s.", type(name))
        return false
    end
    if not params or type(params) ~= "table" then
        log_error(COMPONENT_NAME, "Invalid parameters for '%s': expected table, got %s.", name, type(params))
        return false
    end

    local monitor_obj = self:get_monitor(name)
    if not monitor_obj then
        log_error(COMPONENT_NAME, "DVB Monitor '%s' not found. Cannot update parameters.", name)
        return false
    end
    if monitor_obj.update_parameters and type(monitor_obj.update_parameters) == "function" then
        local success, err = pcall(monitor_obj.update_parameters, monitor_obj, params)
        if success then
            log_info(COMPONENT_NAME, "Parameters updated successfully for DVB monitor '%s'.", name)
            return true
        else
            log_error(COMPONENT_NAME, "Error updating parameters for DVB monitor '%s': %s", name, tostring(err))
            return false
        end
    else
        log_error(COMPONENT_NAME, "DVB Monitor '%s' does not support update_parameters method.", name)
        return false
    end
end

return DvbMonitorManager
