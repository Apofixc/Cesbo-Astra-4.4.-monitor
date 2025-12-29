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
local ChannelMonitorDispatcher = {}
ChannelMonitorDispatcher.__index = ChannelMonitorDispatcher
local instance = nil
local validate_monitor_name = Utils.validate_monitor_name

--- Создает новый экземпляр ChannelMonitorDispatcher (или возвращает существующий).
-- Инициализирует пустую таблицу для хранения объектов мониторов каналов.
-- @return ChannelMonitorDispatcher Единственный объект ChannelMonitorDispatcher.
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
-- @param string name Уникальное имя монитора.
-- @param table monitor_obj Объект монитора канала, который должен быть таблицей.
-- @return boolean true, если монитор успешно добавлен; `nil` и сообщение об ошибке в случае ошибки.
function ChannelMonitorDispatcher:add_monitor(name, monitor_obj)
    local is_name_valid, name_err = validate_monitor_name(name)
    if not is_name_valid then
        return nil, name_err
    end
    if not monitor_obj or type(monitor_obj) ~= "table" then
        local error_msg = "Неверный объект монитора для '%s': ожидалась таблица, получено: %s.", name, type(monitor_obj)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if self.monitors[name] then
        local error_msg = "Монитор с именем '%s' уже существует. Невозможно добавить дубликат.", name
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if self.count >= MonitorConfig.ChannelMonitorLimit then
        local error_msg = string.format("Переполнение списка мониторов каналов. Невозможно добавить более %s мониторов.", MonitorConfig.ChannelMonitorLimit)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    self.monitors[name] = monitor_obj
    self.count = self.count + 1
    log_info(COMPONENT_NAME, "Монитор канала '%s' успешно добавлен. Всего: %d.", name, self.count)
    return true, nil
end

--- Создает, инициализирует и регистрирует новый монитор канала.
-- Этот метод централизует логику создания монитора, включая проверку лимитов,
-- инициализацию upstream и запуск монитора.
-- @param table config Таблица конфигурации для нового монитора.
-- @param table channel_data (optional) Таблица с данными канала или его имя (string).
-- @return userdata monitor Экземпляр монитора, если успешно создан и зарегистрирован, иначе `nil` и сообщение об ошибке.
function ChannelMonitorDispatcher:create_and_register_channel_monitor(config, channel_data)
    if not config or type(config) ~= 'table' then
        local error_msg = "Неверная таблица конфигурации. Ожидалась таблица, получено: %s.", type(config)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
    if not config.name or type(config.name) ~= 'string' then
        local error_msg = "config.name является обязательным и должен быть строкой."
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local existing_monitor, get_err = self:get_monitor(config.name)
    if get_err then
        log_error(COMPONENT_NAME, get_err)
        return nil, get_err
    end
    if existing_monitor then
        local error_msg = "Монитор с именем '%s' уже существует.", config.name
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
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
    local instance, err = monitor:start()

    if instance then
        local success, add_err = self:add_monitor(monitor.name, monitor)
        if success then
            log_info(COMPONENT_NAME, "Монитор канала '%s' успешно создан и добавлен.", monitor.name)
            return instance, nil
        else
            log_error(COMPONENT_NAME, "Не удалось добавить монитор канала '%s' в диспетчер: %s.", monitor.name, add_err or "неизвестная ошибка")
            return nil, add_err or "Не удалось добавить монитор в диспетчер"
        end
    else
        local error_msg = "ChannelMonitor:start вернул nil для монитора '%s'. Ошибка: %s.", (config.name or "unknown"), (err or "unknown")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
end

--- Получает объект монитора канала по его имени.
-- @param string name Уникальное имя монитора.
-- @return table Объект монитора, если найден; `nil` и сообщение об ошибке, если монитор с таким именем не существует или имя невалидно.
function ChannelMonitorDispatcher:get_monitor(name)
    local is_name_valid, name_err = validate_monitor_name(name)
    if not is_name_valid then
        return nil, name_err
    end
    return self.monitors[name], nil
end

--- Удаляет монитор канала из диспетчера по его имени.
-- Если монитор имеет метод `kill()`, он будет вызван перед удалением.
-- @param string name Уникальное имя монитора.
-- @return boolean true, если монитор успешно удален; `nil` и сообщение об ошибке в случае ошибки.
function ChannelMonitorDispatcher:remove_monitor(name)
    local is_name_valid, name_err = validate_monitor_name(name)
    if not is_name_valid then
        return nil, name_err
    end
    local monitor_obj, get_err = self:get_monitor(name)
    if not monitor_obj then
        local error_msg = "Монитор с именем '%s' не найден. Невозможно удалить. Ошибка: %s.", name, (get_err or "неизвестная ошибка")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
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
-- Ключами таблицы являются имена мониторов, значениями - соответствующие объекты мониторов.
-- @return table Таблица, содержащая все объекты мониторов каналов.
function ChannelMonitorDispatcher:get_all_monitors()
    return self.monitors
end

--- Обновляет параметры существующего монитора канала по его имени.
-- Если монитор поддерживает метод `update_parameters`, он будет вызван с новыми параметрами.
-- @param string name Уникальное имя монитора.
-- @param table params Таблица, содержащая новые параметры для обновления.
-- @return boolean true, если параметры успешно обновлены; `nil` и сообщение об ошибке в случае ошибки.
function ChannelMonitorDispatcher:update_monitor_parameters(name, params)
    local is_name_valid, name_err = validate_monitor_name(name)
    if not is_name_valid then
        return nil, name_err
    end
    if not params or type(params) ~= "table" then
        local error_msg = "Неверные параметры для '%s': ожидалась таблица, получено: %s.", name, type(params)
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end

    local monitor_obj, get_err = self:get_monitor(name)
    if not monitor_obj then
        local error_msg = "Монитор канала '%s' не найден. Невозможно обновить параметры. Ошибка: %s.", name, (get_err or "неизвестная ошибка")
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
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
