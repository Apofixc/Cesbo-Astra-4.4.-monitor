-- ===========================================================================
-- ChannelMonitorManager Class
-- Управляет жизненным циклом и состоянием мониторов каналов.
-- ===========================================================================

local type        = type
local Logger      = require "utils.logger"
local log_info    = Logger.info
local log_error   = Logger.error

local ChannelMonitor = require "channel.channel_monitor"
local MonitorConfig  = require "config.monitor_config"
local Utils          = require "utils.utils" -- Добавляем require для utils.utils
local validate_monitor_name = Utils.validate_monitor_name

-- Предполагаем, что эти глобальные функции доступны в окружении Astra
local parse_url = parse_url
local init_input = init_input

local COMPONENT_NAME = "ChannelMonitorManager"

local ChannelMonitorManager = {}
ChannelMonitorManager.__index = ChannelMonitorManager

local instance = nil -- Переменная для хранения единственного экземпляра

--- Создает новый экземпляр ChannelMonitorManager (или возвращает существующий).
-- Инициализирует пустую таблицу для хранения объектов мониторов каналов.
-- @return ChannelMonitorManager Единственный объект ChannelMonitorManager.
function ChannelMonitorManager:new()
    if not instance then
        local self = setmetatable({}, ChannelMonitorManager)
        self.monitors = {} -- Таблица для хранения мониторов каналов по их уникальному имени
        self.count = 0     -- Явный счетчик мониторов
        instance = self
        log_info(COMPONENT_NAME, "ChannelMonitorManager initialized.")
    end
    return instance
end

--- Добавляет уже созданный и запущенный объект монитора канала в менеджер.
-- @param string name Уникальное имя монитора.
-- @param table monitor_obj Объект монитора канала, который должен быть таблицей.
-- @return boolean true, если монитор успешно добавлен; `nil` и сообщение об ошибке в случае ошибки.
function ChannelMonitorManager:add_monitor(name, monitor_obj)
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
    if self.count >= MonitorConfig.ChannelMonitorLimit then
        local error_msg = string.format("Channel Monitor list overflow. Cannot add more than %s monitors.", MonitorConfig.ChannelMonitorLimit)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    self.monitors[name] = monitor_obj
    self.count = self.count + 1
    log_info(COMPONENT_NAME, "Channel Monitor '%s' added successfully. Total: %d", name, self.count)
    return true, nil
end

--- Создает, инициализирует и регистрирует новый монитор канала.
-- Этот метод централизует логику создания монитора, включая проверку лимитов,
-- инициализацию upstream и запуск монитора.
-- @param table config Таблица конфигурации для нового монитора.
-- @param table channel_data (optional) Таблица с данными канала или его имя (string).
-- @return userdata monitor Экземпляр монитора, если успешно создан и зарегистрирован, иначе `nil` и сообщение об ошибке.
function ChannelMonitorManager:create_and_register_channel_monitor(config, channel_data)
    if not config or type(config) ~= 'table' then
        local error_msg = "Invalid configuration table. Expected table, got " .. type(config) .. "."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not config.name or type(config.name) ~= 'string' then
        local error_msg = "config.name is required and must be a string."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    if self:get_monitor(config.name) then
        local error_msg = "Monitor with name '" .. config.name .. "' already exists."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    -- Инициализация upstream, если он не предоставлен
    if not config.upstream then
        if not parse_url then
            local error_msg = "Global function 'parse_url' is not available."
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
        if not init_input then
            local error_msg = "Global function 'init_input' is not available."
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end

        local cfg = parse_url(config.monitor)
        if not cfg then
            local error_msg = "Monitoring address does not exist for channel '" .. config.name .. "'."
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
        cfg.name = config.name
        local input_instance = init_input(cfg)
        if not input_instance then
            local error_msg = "init_input returned nil, upstream is required for channel '" .. config.name .. "'."
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
        config.upstream = input_instance.tail
        log_info(COMPONENT_NAME, "Upstream initialized for channel '%s' from monitor config.", config.name)
    else
        log_info(COMPONENT_NAME, "Upstream already provided for channel '%s'. Skipping initialization.", config.name)
    end

    local monitor = ChannelMonitor:new(config, channel_data)
    local instance, err = monitor:start()

    if instance then
        local success, add_err = self:add_monitor(monitor.name, monitor)
        if success then
            log_info(COMPONENT_NAME, "Channel monitor '%s' created and added successfully.", monitor.name)
            return instance, nil
        else
            log_error(COMPONENT_NAME, "Failed to add channel monitor '%s' to manager: %s", monitor.name, add_err or "unknown error")
            return nil, add_err or "Failed to add monitor to manager"
        end
    else
        local error_msg = "ChannelMonitor:start returned nil for monitor '" .. (config.name or "unknown") .. "'. Error: " .. (err or "unknown")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
end

--- Получает объект монитора канала по его имени.
-- @param string name Уникальное имя монитора.
-- @return table Объект монитора, если найден; `nil` и сообщение об ошибке, если монитор с таким именем не существует или имя невалидно.
function ChannelMonitorManager:get_monitor(name)
    local is_name_valid, name_err = validate_monitor_name(name)
    if not is_name_valid then
        return nil, name_err
    end
    return self.monitors[name], nil
end

--- Удаляет монитор канала из менеджера по его имени.
-- Если монитор имеет метод `kill()`, он будет вызван перед удалением.
-- @param string name Уникальное имя монитора.
-- @return boolean true, если монитор успешно удален; `nil` и сообщение об ошибке в случае ошибки.
function ChannelMonitorManager:remove_monitor(name)
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
        log_info(COMPONENT_NAME, "Called kill() on channel monitor '%s'.", name)
    else
        log_info(COMPONENT_NAME, "Channel Monitor '%s' does not have a kill() method.", name)
    end
    self.monitors[name] = nil
    self.count = self.count - 1 -- Уменьшаем счетчик активных мониторов
    log_info(COMPONENT_NAME, "Channel Monitor '%s' removed successfully. Total: %d", name, self.count)
    return true, nil
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
-- @return boolean true, если параметры успешно обновлены; `nil` и сообщение об ошибке в случае ошибки.
function ChannelMonitorManager:update_monitor_parameters(name, params)
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
        local error_msg = "Channel Monitor '" .. name .. "' not found. Cannot update parameters. Error: " .. (get_err or "unknown")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if monitor_obj.update_parameters and type(monitor_obj.update_parameters) == "function" then
        local success, err = pcall(monitor_obj.update_parameters, monitor_obj, params)
        if success then
            log_info(COMPONENT_NAME, "Parameters updated successfully for channel monitor '%s'.", name)
            return true, nil
        else
            local error_msg = "Error updating parameters for channel monitor '" .. name .. "': " .. tostring(err)
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
    else
        local error_msg = "Channel Monitor '" .. name .. "' does not support update_parameters method."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
end

return ChannelMonitorManager
