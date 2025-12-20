-- ===========================================================================
-- MonitorManager Class
-- ===========================================================================

local type = type
local Logger = require "utils.logger" -- Импортируем новый модуль логирования
local log_info = Logger.info
local log_error = Logger.error

local ChannelMonitor = require "channel.channel_monitor" -- Для создания экземпляров мониторов
local MonitorConfig = require "config.monitor_config"   -- Для доступа к лимитам мониторов

-- Предполагаем, что эти глобальные функции доступны в окружении Astra
local parse_url = parse_url
local init_input = init_input

local COMPONENT_NAME = "MonitorManager" -- Имя компонента для логирования

local MonitorManager = {}
MonitorManager.__index = MonitorManager

--- Создает новый экземпляр MonitorManager.
-- Инициализирует пустую таблицу для хранения объектов мониторов.
-- @return MonitorManager Новый объект MonitorManager.
function MonitorManager:new()
    local self = setmetatable({}, MonitorManager)
    self.monitors = {} -- Таблица для хранения мониторов по их уникальному имени
    return self
end

--- Внутренний метод для добавления уже созданного и запущенного объекта монитора в менеджер.
-- Этот метод не выполняет проверок лимитов или инициализации upstream,
-- предполагая, что эти шаги уже были выполнены перед вызовом.
-- @param string name Уникальное имя монитора.
-- @param table monitor_obj Объект монитора, который должен быть таблицей.
-- @return boolean true, если монитор успешно добавлен; false в случае ошибки (неверное имя, неверный объект, дубликат имени).
function MonitorManager:_add_monitor_internal(name, monitor_obj)
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

--- Создает, инициализирует и регистрирует новый монитор канала.
-- Этот метод централизует логику создания монитора, включая проверку лимитов,
-- инициализацию upstream и запуск монитора.
-- @param table config Таблица конфигурации для нового монитора.
-- @param table channel_data (optional) Таблица с данными канала или его имя (string).
-- @return userdata monitor Экземпляр монитора, если успешно создан и зарегистрирован, иначе false.
function MonitorManager:create_and_register_monitor(config, channel_data)
    if #self.monitors > MonitorConfig.MonitorLimit then
        log_error(COMPONENT_NAME, "Monitor list overflow. Cannot create more than " .. MonitorConfig.MonitorLimit .. " monitors.")
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
            log_error(COMPONENT_NAME, "Monitoring address does not exist for channel '" .. config.name .. "'.")
            return false
        end
        cfg.name = config.name
        local input_instance = init_input(cfg)
        if not input_instance then
            log_error(COMPONENT_NAME, "init_input returned nil, upstream is required for channel '" .. config.name .. "'.")
            return false
        end
        config.upstream = input_instance.tail
        log_info(COMPONENT_NAME, "Upstream initialized for channel '" .. config.name .. "' from monitor config.")
    else
        log_info(COMPONENT_NAME, "Upstream already provided for channel '" .. config.name .. "'. Skipping initialization.")
    end

    local monitor = ChannelMonitor:new(config, channel_data)
    local instance = monitor:start()

    if instance then
        self:_add_monitor_internal(monitor.name, monitor)
        log_info(COMPONENT_NAME, "Channel monitor '" .. monitor.name .. "' created and added successfully.")
        return instance
    else
        log_error(COMPONENT_NAME, "ChannelMonitor:start returned nil for monitor '" .. (config.name or "unknown") .. "'.")
        return false
    end
end

--- Получает объект монитора по его имени.
-- @param string name Уникальное имя монитора.
-- @return table Объект монитора, если найден; nil, если монитор с таким именем не существует или имя невалидно.
function MonitorManager:get_monitor(name)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Invalid name: expected string, got " .. type(name) .. ".")
        return nil
    end
    return self.monitors[name]
end

--- Удаляет монитор из менеджера по его имени.
-- Если монитор имеет метод `kill()`, он будет вызван перед удалением.
-- @param string name Уникальное имя монитора.
-- @return boolean true, если монитор успешно удален; false в случае ошибки (неверное имя, монитор не найден).
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

--- Возвращает таблицу всех активных мониторов, управляемых менеджером.
-- Ключами таблицы являются имена мониторов, значениями - соответствующие объекты мониторов.
-- @return table Таблица, содержащая все объекты мониторов.
function MonitorManager:get_all_monitors()
    return self.monitors
end

--- Обновляет параметры существующего монитора по его имени.
-- Если монитор поддерживает метод `update_parameters`, он будет вызван с новыми параметрами.
-- @param string name Уникальное имя монитора.
-- @param table params Таблица, содержащая новые параметры для обновления.
-- @return boolean true, если параметры успешно обновлены; false в случае ошибки (неверное имя, неверные параметры, монитор не найден, или метод `update_parameters` не поддерживается/вызвал ошибку).
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
