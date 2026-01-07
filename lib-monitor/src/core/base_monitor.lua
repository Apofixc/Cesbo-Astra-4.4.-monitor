--- @class BaseMonitor
--- @field protected _name string Технический идентификатор монитора
--- @field protected _config table Конфигурация монитора
--- @field protected _component_name string Имя компонента для логирования
--- @field protected _active boolean Флаг активности мониторинга
--- @field protected _state number Текущее состояние (IDLE, RUNNING, STOPPED)
--- @field protected _instance any|nil Экземпляр Astra (анализатор или тюнер)
--- @field protected _json_cache string|nil Кэш последнего отправленного JSON
--- @field protected _reports table Пул таблиц для разных типов отчетов
--- @field protected _current_method function|nil Прямая ссылка на метод сравнения
local BaseMonitor = {}
BaseMonitor.__index = BaseMonitor

-- 1. Стандартные Lua функции
local setmetatable = setmetatable
local type = type
local tostring = tostring

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local HttpSubscriber = ModuleManager.get_module("http_subscriber")
local Utils = ModuleManager.get_module("utils")

-- 4. Константы
BaseMonitor.STATE = {
    IDLE = 1,
    RUNNING = 2,
    STOPPED = 3,
}

--- Конструктор базового монитора
--- @param config table Конфигурация
--- @param component_name string Имя компонента для логирования
--- @return BaseMonitor
function BaseMonitor.new(config, component_name)
    --- @type BaseMonitor
    local self = setmetatable({}, BaseMonitor)
    self._config = config
    self._component_name = component_name or "BaseMonitor"
    self._active = false
    self._state = BaseMonitor.STATE.IDLE
    self._instance = nil
    self._json_cache = nil
    self._reports = {}
    return self
end

--- Вспомогательная функция для установки параметра конфигурации
--- @protected
--- @param param_name string Имя параметра (с префиксом)
--- @param value any Значение
--- @param prefix string Префикс для удаления (например, "dvb_" или "channel_")
--- @return boolean Статус выполнения
function BaseMonitor:_set_config_param(param_name, value, prefix)
    local result = Utils.validate_monitor_param(param_name, value)
    if result == nil then
        Logger.error(self._component_name, "[%s] Invalid parameter value for %s: %s", 
            tostring(self._name), param_name, tostring(value))
        return false
    end
    local key = param_name:gsub(prefix, "")
    self._config[key] = result
    return true
end

--- Публикует данные через HttpSubscriber
--- @param content string JSON данные
--- @param event_type string Тип события
function BaseMonitor:publish(content, event_type)
    HttpSubscriber.publish(event_type, content)
end

--- Возвращает оригинальную конфигурацию
--- @return table Конфигурация
function BaseMonitor:get_config()
    return self._config
end

--- Возвращает технический идентификатор
--- @return string Имя монитора
function BaseMonitor:get_name()
    return self._name
end

--- Возвращает экземпляр Astra
--- @return any|nil Экземпляр Astra
function BaseMonitor:get_instance()
    return self._instance
end

--- Возвращает текущее состояние
--- @return number Состояние (STATE)
function BaseMonitor:get_state()
    return self._state
end

--- Возвращает кэш последнего отправленного JSON
--- @return string|nil JSON статус
function BaseMonitor:get_json_cache()
    return self._json_cache
end

--- Приостанавливает мониторинг
function BaseMonitor:pause()
    self._active = false
    Logger.info(self._component_name, "[%s] Monitoring paused", tostring(self._name))
end

--- Возобновляет мониторинг
--- @return boolean Статус выполнения
function BaseMonitor:resume()
    if self._state == BaseMonitor.STATE.STOPPED then
        Logger.error(self._component_name, "[%s] Cannot resume: monitor already stopped", tostring(self._name))
        return false
    end
    self._active = true
    Logger.info(self._component_name, "[%s] Monitoring resumed", tostring(self._name))
    return true
end

return BaseMonitor
