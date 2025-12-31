-- ===========================================================================
-- Класс `ChannelMonitorDispatcher`
--
-- Управляет жизненным циклом и состоянием мониторов каналов,
-- обеспечивая их создание, регистрацию, обновление параметров и удаление.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local log_info = Logger.info
local log_error = Logger.error
local ChannelMonitor = ModuleManager.get_module("channel_monitor")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Utils = ModuleManager.get_module("utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local parse_url = ModuleManager.get_global_dependency("parse_url")
local init_input = ModuleManager.get_global_dependency("init_input")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelMonitorDispatcher"

-- 5. Инициализация объектов из загруженных модулей
--- @class ChannelMonitorDispatcher
--- @field monitors table<string, ChannelMonitor> Таблица для хранения мониторов каналов
--- @field count number Счетчик мониторов
local ChannelMonitorDispatcher = {}
ChannelMonitorDispatcher.__index = ChannelMonitorDispatcher
--- @type ChannelMonitorDispatcher|nil
local instance = nil
local validate_monitor_name = Utils.validate_monitor_name

--- Создает новый экземпляр ChannelMonitorDispatcher (или возвращает существующий).
--- Инициализирует пустую таблицу для хранения объектов мониторов каналов.
--- @return ChannelMonitorDispatcher Единственный объект ChannelMonitorDispatcher.
function ChannelMonitorDispatcher:new()
    if not instance then
        local self = setmetatable({}, ChannelMonitorDispatcher)
        self.monitors = {} -- Таблица для хранения мониторов каналов по их уникальному имени
        self.count = 0     -- Явный счетчик мониторов
        instance = self
        log_info(COMPONENT_NAME, "ChannelMonitorDispatcher инициализирован.")
    end
    return instance
end

--- Добавляет уже созданный и запущенный объект монитора канала в диспетчер.
--- @param name string Уникальное имя монитора.
--- @param monitor_obj ChannelMonitor Объект монитора канала.
--- @return boolean success Статус выполнения
--- @return nil result
function ChannelMonitorDispatcher:add_monitor(name, monitor_obj)
    local is_name_valid = validate_monitor_name(name)
    if not is_name_valid then
        return false, nil
    end
    if not monitor_obj or type(monitor_obj) ~= "table" then
        log_error(COMPONENT_NAME, "Неверный объект монитора для '%s': ожидалась таблица, получено: %s.", name, type(monitor_obj))
        return false, nil
    end
    if self.monitors[name] then
        log_error(COMPONENT_NAME, "Монитор с именем '%s' уже существует. Невозможно добавить дубликат.", name)
        return false, nil
    end
    if self.count >= MonitorConfig.ChannelMonitorLimit then
        log_error(COMPONENT_NAME, "Переполнение списка мониторов каналов. Невозможно добавить более %s мониторов.", MonitorConfig.ChannelMonitorLimit)
        return false, nil
    end

    self.monitors[name] = monitor_obj
    self.count = self.count + 1
    log_info(COMPONENT_NAME, "Монитор канала '%s' успешно добавлен. Всего: %d.", name, self.count)
    return true
end

--- Создает, инициализирует и регистрирует новый монитор канала.
--- Этот метод централизует логику создания монитора, включая проверку лимитов,
--- инициализацию upstream и запуск монитора.
--- @param config table Таблица конфигурации для нового монитора.
--- @param [channel_data] table|string|nil Таблица с данными канала или его имя (string).
--- @return boolean success Статус выполнения
--- @return any|nil result Экземпляр монитора или nil
function ChannelMonitorDispatcher:create_and_register_channel_monitor(config, channel_data)
    if not config or type(config) ~= 'table' then
        log_error(COMPONENT_NAME, "Неверная таблица конфигурации. Ожидалась таблица, получено: %s.", type(config))
        return false, nil
    end
    if not config.name or type(config.name) ~= 'string' then
        log_error(COMPONENT_NAME, "config.name является обязательным и должен быть строкой.")
        return false, nil
    end

    local success_get, existing_monitor = self:get_monitor(config.name)
    if existing_monitor then
        log_error(COMPONENT_NAME, "Монитор с именем '%s' уже существует.", config.name)
        return false, nil
    end

    -- Инициализация upstream, если он не предоставлен
    if not config.upstream then
        if not parse_url then
            local error_msg = "Глобальная функция 'parse_url' недоступна."
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
        if not init_input then
            local error_msg = "Глобальная функция 'init_input' недоступна."
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end

        local cfg = parse_url(config.monitor)
        if not cfg then
            local error_msg = "Адрес мониторинга не существует для канала '%s'.", config.name
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
        cfg.name = config.name
        local input_instance = init_input(cfg)
        if not input_instance then
            local error_msg = "init_input вернул nil, upstream требуется для канала '%s'.", config.name
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
        config.upstream = input_instance.tail
        log_info(COMPONENT_NAME, "Upstream инициализирован для канала '%s' из конфигурации монитора.", config.name)
    else
        log_info(COMPONENT_NAME, "Upstream уже предоставлен для канала '%s'. Пропускаем инициализацию.", config.name)
    end

    local monitor = ChannelMonitor:new(config, channel_data)
    local success_start, instance = monitor:start()

    if success_start then
        local success_add = self:add_monitor(monitor.name, monitor)
        if success_add then
            log_info(COMPONENT_NAME, "Монитор канала '%s' успешно создан и добавлен.", monitor.name)
            return true, instance
        else
            log_error(COMPONENT_NAME, "Не удалось добавить монитор канала '%s' в диспетчер.", monitor.name)
            return false, nil
        end
    else
        log_error(COMPONENT_NAME, "ChannelMonitor:start вернул nil для монитора '%s'.", (config.name or "unknown"))
        return false, nil
    end
end

--- Получает объект монитора канала по его имени.
--- @param name string Уникальное имя монитора.
--- @return boolean success Статус выполнения
--- @return ChannelMonitor|nil result Объект монитора или nil
function ChannelMonitorDispatcher:get_monitor(name)
    local is_name_valid = validate_monitor_name(name)
    if not is_name_valid then
        return false, nil
    end
    return true, self.monitors[name]
end

--- Удаляет монитор канала из диспетчера по его имени.
--- Если монитор имеет метод `kill()`, он будет вызван перед удалением.
--- @param name string Уникальное имя монитора.
--- @return boolean success Статус выполнения
--- @return nil result
function ChannelMonitorDispatcher:remove_monitor(name)
    local is_name_valid = validate_monitor_name(name)
    if not is_name_valid then
        return false, nil
    end
    local success_get, monitor_obj = self:get_monitor(name)
    if not success_get or not monitor_obj then
        log_error(COMPONENT_NAME, "Монитор с именем '%s' не найден. Невозможно удалить.", name)
        return false, nil
    end
    if monitor_obj.kill and type(monitor_obj.kill) == "function" then
        monitor_obj:kill() -- Вызываем метод kill у самого монитора
        log_info(COMPONENT_NAME, "Вызван kill() для монитора канала '%s'.", name)
    else
        log_info(COMPONENT_NAME, "Монитор канала '%s' не имеет метода kill().", name)
    end
    self.monitors[name] = nil
    self.count = self.count - 1 -- Уменьшаем счетчик активных мониторов
    log_info(COMPONENT_NAME, "Монитор канала '%s' успешно удален. Всего: %d.", name, self.count)
    return true, nil
end

--- Возвращает таблицу всех активных мониторов каналов, управляемых диспетчером.
--- Ключами таблицы являются имена мониторов, значениями - соответствующие объекты мониторов.
--- @return table<string, ChannelMonitor> monitors Таблица, содержащая все объекты мониторов каналов.
function ChannelMonitorDispatcher:get_all_monitors()
    return self.monitors
end

--- Обновляет параметры существующего монитора канала по его имени.
--- Если монитор поддерживает метод `update_parameters`, он будет вызван с новыми параметрами.
--- @param name string Уникальное имя монитора.
--- @param params table Таблица, содержащая новые параметры для обновления.
--- @return boolean success Статус выполнения
--- @return nil result
function ChannelMonitorDispatcher:update_monitor_parameters(name, params)
    local is_name_valid = validate_monitor_name(name)
    if not is_name_valid then
        return false, nil
    end
    if not params or type(params) ~= "table" then
        log_error(COMPONENT_NAME, "Неверные параметры для '%s': ожидалась таблица, получено: %s.", name, type(params))
        return false, nil
    end

    local success_get, monitor_obj = self:get_monitor(name)
    if not success_get or not monitor_obj then
        log_error(COMPONENT_NAME, "Монитор канала '%s' не найден. Невозможно обновить параметры.", name)
        return false, nil
    end
    if monitor_obj.update_parameters and type(monitor_obj.update_parameters) == "function" then
        local success, err = pcall(monitor_obj.update_parameters, monitor_obj, params)
        if success then
            log_info(COMPONENT_NAME, "Параметры успешно обновлены для монитора канала '%s'.", name)
            return true, nil
        else
            local error_msg = "Ошибка при обновлении параметров для монитора канала '%s': %s.", name, tostring(err)
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
    else
        local error_msg = "Монитор канала '%s' не поддерживает метод update_parameters.", name
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
end

return ChannelMonitorDispatcher
