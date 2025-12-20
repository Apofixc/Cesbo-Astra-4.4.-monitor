-- ===========================================================================
-- ChannelMonitorManager Class
-- Управляет жизненным циклом и состоянием мониторов каналов.
-- ===========================================================================

local type = type
local Logger = require "utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local ChannelMonitor = require "channel.channel_monitor"
local MonitorConfig = require "config.monitor_config"

-- Предполагаем, что эти глобальные функции доступны в окружении Astra
local parse_url = parse_url
local init_input = init_input

local COMPONENT_NAME = "ChannelMonitorManager"

local ChannelMonitorManager = {}
ChannelMonitorManager.__index = ChannelMonitorManager

--- Создает новый экземпляр ChannelMonitorManager.
-- Инициализирует пустую таблицу для хранения объектов мониторов каналов.
-- @return ChannelMonitorManager Новый объект ChannelMonitorManager.
function ChannelMonitorManager:new()
    local self = setmetatable({}, ChannelMonitorManager)
    self.monitors = {} -- Таблица для хранения мониторов каналов по их уникальному имени
    return self
end

--- Добавляет уже созданный и запущенный объект монитора канала в менеджер.
-- @param string name Уникальное имя монитора.
-- @param table monitor_obj Объект монитора канала, который должен быть таблицей.
-- @return boolean true, если монитор успешно добавлен; false в случае ошибки.
function ChannelMonitorManager:add_monitor(name, monitor_obj)
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
    if #self.monitors >= MonitorConfig.ChannelMonitorLimit then -- Предполагаем, что есть ChannelMonitorLimit
        log_error(COMPONENT_NAME, "Channel Monitor list overflow. Cannot create more than %d monitors.", MonitorConfig.ChannelMonitorLimit)
        return false
    end

    self.monitors[name] = monitor_obj
    log_info(COMPONENT_NAME, "Channel Monitor '%s' added successfully.", name)
    return true
end

--- Создает, инициализирует и регистрирует новый монитор канала.
-- Этот метод централизует логику создания монитора, включая проверку лимитов,
-- инициализацию upstream и запуск монитора.
-- @param table config Таблица конфигурации для нового монитора.
-- @param table channel_data (optional) Таблица с данными канала или его имя (string).
-- @return userdata monitor Экземпляр монитора, если успешно создан и зарегистрирован, иначе false.
function ChannelMonitorManager:create_and_register_channel_monitor(config, channel_data)
    if not config or type(config) ~= 'table' then
        log_error(COMPONENT_NAME, "Invalid configuration table.")
        return false
    end
    if not config.name or type(config.name) ~= 'string' then
        log_error(COMPONENT_NAME, "config.name is required and must be a string.")
        return false
    end

    if self:get_monitor(config.name) then
        log_error(COMPONENT_NAME, "Monitor with name '%s' already exists.", config.name)
        return false
    end

    -- Инициализация upstream, если он не предоставлен
    if not config.upstream then
        if not parse_url then
            log_error(COMPONENT_NAME, "Global function 'parse_url' is not available.")
            return false
        end
        if not init_input then
            log_error(COMPONENT_NAME, "Global function 'init_input' is not available.")
            return false
        end

        local cfg = parse_url(config.monitor)
        if not cfg then
            log_error(COMPONENT_NAME, "Monitoring address does not exist for channel '%s'.", config.name)
            return false
        end
        cfg.name = config.name
        local input_instance = init_input(cfg)
        if not input_instance then
            log_error(COMPONENT_NAME, "init_input returned nil, upstream is required for channel '%s'.", config.name)
            return false
        end
        config.upstream = input_instance.tail
        log_info(COMPONENT_NAME, "Upstream initialized for channel '%s' from monitor config.", config.name)
    else
        log_info(COMPONENT_NAME, "Upstream already provided for channel '%s'. Skipping initialization.", config.name)
    end

    local monitor = ChannelMonitor:new(config, channel_data)
    local instance = monitor:start()

    if instance then
        self:add_monitor(monitor.name, monitor)
        log_info(COMPONENT_NAME, "Channel monitor '%s' created and added successfully.", monitor.name)
        return instance
    else
        log_error(COMPONENT_NAME, "ChannelMonitor:start returned nil for monitor '%s'.", (config.name or "unknown"))
        return false
    end
end

--- Получает объект монитора канала по его имени.
-- @param string name Уникальное имя монитора.
-- @return table Объект монитора, если найден; nil, если монитор с таким именем не существует или имя невалидно.
function ChannelMonitorManager:get_monitor(name)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got %s.", type(name))
        return nil
    end
    return self.monitors[name]
end

--- Удаляет монитор канала из менеджера по его имени.
-- Если монитор имеет метод `kill()`, он будет вызван перед удалением.
-- @param string name Уникальное имя монитора.
-- @return boolean true, если монитор успешно удален; false в случае ошибки.
function ChannelMonitorManager:remove_monitor(name)
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
        log_info(COMPONENT_NAME, "Called kill() on channel monitor '%s'.", name)
    else
        log_info(COMPONENT_NAME, "Channel Monitor '%s' does not have a kill() method.", name)
    end
    self.monitors[name] = nil
    log_info(COMPONENT_NAME, "Channel Monitor '%s' removed successfully.", name)
    return true
end

--- Возвращает таблицу всех активных мониторов каналов, управляемых менеджером.
-- Ключами таблицы являются имена мониторов, значениями - соответствующие объекты мониторов.
-- @return table Таблица, содержащая все объекты мониторов каналов.
function ChannelMonitorManager:get_all_monitors()
    return self.monitors
end

--- Обновляет параметры существующего монитора канала по его имени.
-- Если монитор поддерживает метод `update_parameters`, он будет вызван с новыми параметрами.
-- @param string name Уникальное имя монитора.
-- @param table params Таблица, содержащая новые параметры для обновления.
-- @return boolean true, если параметры успешно обновлены; false в случае ошибки.
function ChannelMonitorManager:update_monitor_parameters(name, params)
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
        log_error(COMPONENT_NAME, "Channel Monitor '%s' not found. Cannot update parameters.", name)
        return false
    end
    if monitor_obj.update_parameters and type(monitor_obj.update_parameters) == "function" then
        local success, err = pcall(monitor_obj.update_parameters, monitor_obj, params)
        if success then
            log_info(COMPONENT_NAME, "Parameters updated successfully for channel monitor '%s'.", name)
            return true
        else
            log_error(COMPONENT_NAME, "Error updating parameters for channel monitor '%s': %s", name, tostring(err))
            return false
        end
    else
        log_error(COMPONENT_NAME, "Channel Monitor '%s' does not support update_parameters method.", name)
        return false
    end
end
end

return ChannelMonitorManager
