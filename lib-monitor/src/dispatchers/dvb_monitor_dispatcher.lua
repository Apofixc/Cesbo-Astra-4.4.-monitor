-- ===========================================================================
-- Класс `DvbMonitorDispatcher`
--
-- Управляет жизненным циклом и состоянием DVB-тюнер мониторов,
-- обеспечивая их создание, регистрацию, обновление параметров и удаление.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local log_info = Logger.info
local log_error = Logger.error
local DvbTunerMonitor = ModuleManager.get_module("dvb_tuner")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Utils = ModuleManager.get_module("utils")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет глобальных зависимостей Astra в этом модуле

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbMonitorDispatcher"

-- 5. Инициализация объектов из загруженных модулей
--- @class DvbMonitorDispatcher
--- @field monitors table<string, DvbTunerMonitor> Таблица для хранения DVB-мониторов
--- @field count number Счетчик мониторов
local DvbMonitorDispatcher = {}
DvbMonitorDispatcher.__index = DvbMonitorDispatcher
--- @type DvbMonitorDispatcher|nil
local instance = nil
local validate_monitor_name = Utils.validate_monitor_name

--- Создает новый экземпляр DvbMonitorDispatcher (или возвращает существующий).
--- Инициализирует пустую таблицу для хранения объектов DVB-мониторов.
--- @return DvbMonitorDispatcher Единственный объект DvbMonitorDispatcher.
function DvbMonitorDispatcher:new()
    if not instance then
        local self = setmetatable({}, DvbMonitorDispatcher)
        self.monitors = {} -- Таблица для хранения DVB-мониторов по их уникальному имени
        self.count = 0     -- Явный счетчик мониторов
        instance = self
        log_info(COMPONENT_NAME, "DvbMonitorDispatcher инициализирован.")
    end
    return instance
end

--- Добавляет уже созданный и запущенный объект DVB-монитора в диспетчер.
--- @param name string Уникальное имя монитора.
--- @param monitor_obj DvbTunerMonitor Объект DVB-монитора.
--- @return boolean success Статус выполнения
--- @return nil result
function DvbMonitorDispatcher:add_monitor(name, monitor_obj)
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
    if self.count >= MonitorConfig.DvbMonitorLimit then
        log_error(COMPONENT_NAME, "Переполнение списка DVB-мониторов. Невозможно добавить более %s мониторов.", MonitorConfig.DvbMonitorLimit)
        return false, nil
    end

    self.monitors[name] = monitor_obj
    self.count = self.count + 1
    log_info(COMPONENT_NAME, "DVB-монитор '%s' успешно добавлен. Всего: %d.", name, self.count)
    return true
end

--- Создает, инициализирует и регистрирует новый DVB-тюнер монитор.
--- @param conf table Таблица конфигурации для DVB-тюнера.
--- @return boolean success Статус выполнения
--- @return any|nil result Экземпляр DVB-тюнера или nil
function DvbMonitorDispatcher:create_and_register_dvb_monitor(conf)
    if not conf or type(conf) ~= 'table' then
        log_error(COMPONENT_NAME, "Неверная таблица конфигурации. Ожидалась таблица, получено: %s.", type(conf))
        return false, nil
    end
    if not conf.name_adapter or type(conf.name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "conf.name_adapter является обязательным и должен быть строкой.")
        return false, nil
    end

    local success_get, existing_monitor = self:get_monitor(conf.name_adapter)
    if existing_monitor then
        log_error(COMPONENT_NAME, "Монитор с именем '%s' уже существует.", conf.name_adapter)
        return false, nil
    end

    local monitor = DvbTunerMonitor:new(conf)
    local success_start, instance = monitor:start()

    if success_start then
        local success_add = self:add_monitor(conf.name_adapter, monitor)
        if success_add then
            log_info(COMPONENT_NAME, "DVB-тюнер монитор '%s' запущен и успешно добавлен.", conf.name_adapter)
            return true, instance
        else
            log_error(COMPONENT_NAME, "Не удалось добавить DVB-тюнер монитор '%s' в диспетчер.", conf.name_adapter)
            return false, nil
        end
    else
        log_error(COMPONENT_NAME, "Не удалось запустить DVB-тюнер монитор '%s'.", conf.name_adapter)
        return false, nil
    end
end

--- Получает объект DVB-монитора по его имени.
--- @param name string Уникальное имя монитора.
--- @return boolean success Статус выполнения
--- @return DvbTunerMonitor|nil result Объект монитора или nil
function DvbMonitorDispatcher:get_monitor(name)
    local is_name_valid = validate_monitor_name(name)
    if not is_name_valid then
        return false, nil
    end
    return true, self.monitors[name]
end

--- Удаляет DVB-монитор из диспетчера по его имени.
--- Если монитор имеет метод `kill()`, он будет вызван перед удалением.
--- @param name string Уникальное имя монитора.
--- @return boolean success Статус выполнения
--- @return nil result
function DvbMonitorDispatcher:remove_monitor(name)
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
        log_info(COMPONENT_NAME, "Вызван kill() для DVB-монитора '%s'.", name)
    else
        log_info(COMPONENT_NAME, "DVB-монитор '%s' не имеет метода kill().", name)
    end
    self.monitors[name] = nil
    self.count = self.count - 1
    log_info(COMPONENT_NAME, "DVB-монитор '%s' успешно удален. Всего: %d.", name, self.count)
    return true, nil
end

--- Возвращает таблицу всех активных DVB-мониторов, управляемых диспетчером.
--- Ключами таблицы являются имена мониторов, значениями - соответствующие объекты мониторов.
--- @return table<string, DvbTunerMonitor> monitors Таблица, содержащая все объекты DVB-мониторов.
function DvbMonitorDispatcher:get_all_monitors()
    return self.monitors
end

--- Обновляет параметры существующего DVB-монитора по его имени.
--- Если монитор поддерживает метод `update_parameters`, он будет вызван с новыми параметрами.
--- @param name string Уникальное имя монитора.
--- @param params table Таблица, содержащая новые параметры для обновления.
--- @return boolean success Статус выполнения
--- @return nil result
function DvbMonitorDispatcher:update_monitor_parameters(name, params)
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
        log_error(COMPONENT_NAME, "DVB-монитор '%s' не найден. Невозможно обновить параметры.", name)
        return false, nil
    end
    if monitor_obj.update_parameters and type(monitor_obj.update_parameters) == "function" then
        local success, err = pcall(monitor_obj.update_parameters, monitor_obj, params)
        if success then
            log_info(COMPONENT_NAME, "Параметры успешно обновлены для DVB-монитора '%s'.", name)
            return true, nil
        else
            local error_msg = "Ошибка при обновлении параметров для DVB-монитора '%s': %s.", name, tostring(err)
            log_error(COMPONENT_NAME, error_msg)
            return nil, error_msg
        end
    else
        local error_msg = "DVB-монитор '%s' не поддерживает метод update_parameters.", name
        log_error(COMPONENT_NAME, error_msg)
        return nil, error_msg
    end
end

return DvbMonitorDispatcher
