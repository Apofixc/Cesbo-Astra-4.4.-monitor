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
--- @field protected _psi table|nil Кэш PSI данных
--- @field protected _check_timer number Таймер интервала проверки
--- @field protected _force_timer number Таймер принудительной отправки статуса
--- @field protected _force_interval number Интервал принудительной отправки
local BaseMonitor = {}
BaseMonitor.__index = BaseMonitor

-- 1. Стандартные Lua функции
local setmetatable = setmetatable
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")

-- 3. Глобальные зависимости Astra
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы
BaseMonitor.STATE = {
    IDLE = 1,
    RUNNING = 2,
    STOPPED = 3,
}

-- Кэш для ключей конфигурации (предотвращает лишние аллокации строк в gsub)
local CONFIG_KEY_CACHE = {}

--- Конструктор базового монитора
--- @param config table Конфигурация монитора
--- @param component_name string Имя компонента для логирования
--- @return BaseMonitor Экземпляр базового монитора
function BaseMonitor.new(config, component_name)
    --- @type BaseMonitor
    local self = setmetatable({}, BaseMonitor)
    self._config = config
    self._name = self._config.name or "Unknown"
    self._component_name = component_name or "BaseMonitor"
    self._active = false
    self._state = BaseMonitor.STATE.IDLE
    self._instance = nil
    self._json_cache = nil
    self._reports = {}
    self._psi = {}
    self._check_timer = 0
    self._force_interval = (MonitorConfig and MonitorConfig.ForceSendInterval) or 300
    self._force_timer = self._force_interval -- Сразу готов к отправке
    return self
end

--- Вспомогательная функция для установки параметра конфигурации
--- @protected
--- @param param_name string Имя параметра (с префиксом)
--- @param value any Значение
--- @param prefix string Префикс для удаления (например, "dvb_" или "channel_")
--- @return boolean Статус выполнения
function BaseMonitor:_set_config_param(param_name, value, prefix)
    if not self._config then return false end
    local result = Utils.validate_monitor_param(param_name, value)
    if result == nil then
        Logger.error(self._component_name, "[%s] Invalid parameter value for %s: %s", 
            tostring(self._name), param_name, tostring(value))
        return false
    end
    
    local key = CONFIG_KEY_CACHE[param_name]
    if not key then
        key = param_name:gsub(prefix, "")
        CONFIG_KEY_CACHE[param_name] = key
    end
    
    self._config[key] = result
    return true
end

--- Публикует данные через EventBus.
--- Теперь принимает таблицу и поддерживает ленивую сериализацию.
--- @param data table|string Данные события
--- @param event_type string Тип события
--- @param is_table? boolean [Флаг, что данные из пула таблиц]
function BaseMonitor:publish(data, event_type, is_table)
    local dispatcher = EventDispatcher and EventDispatcher.get_instance()
    if dispatcher then
        dispatcher:emit(event_type, data, nil, { 
            is_table = is_table,
            source = self._name
        })
    end
end

--- Возвращает актуальные данные в виде таблицы (сырые данные).
--- Должен быть переопределен в наследниках.
--- @return table|nil Таблица данных
function BaseMonitor:get_status_table()
    return nil
end

--- Возвращает актуальные данные в виде JSON-строки.
--- Реализует ленивое кэширование.
--- @return string|nil JSON-строка
function BaseMonitor:get_status_json()
    if self._json_cache then return self._json_cache end
    
    local data = self:get_status_table()
    if not data then return nil end
    
    if json_encode then
        self._json_cache = json_encode(data)
    else
        self._json_cache = tostring(data)
    end
    
    return self._json_cache
end

--- Сбрасывает кэш JSON-представления.
--- Вызывается при обновлении данных монитора.
--- @protected
function BaseMonitor:_clear_json_cache()
    self._json_cache = nil
end

--- Возвращает оригинальную конфигурацию
--- @return table Конфигурация монитора
function BaseMonitor:get_config()
    return self._config
end

--- Возвращает технический идентификатор
--- @return string Имя монитора
function BaseMonitor:get_name()
    return self._name
end

--- Возвращает экземпляр Astra
--- @return any|nil Экземпляр Astra (анализатор или тюнер)
function BaseMonitor:get_instance()
    return self._instance
end

--- Возвращает текущее состояние
--- @return number Текущее состояние (STATE)
function BaseMonitor:get_state()
    return self._state
end

--- Возвращает кэш последнего отправленного JSON
--- @return string|nil JSON-статус из кэша
function BaseMonitor:get_json_cache()
    return self._json_cache
end

--- Приостанавливает мониторинг
function BaseMonitor:pause()
    self._active = false
    Logger.info(self._component_name, "[%s] Мониторинг приостановлен", tostring(self._name))
end

--- Обрабатывает входящие PSI данные и сохраняет их в кэш
--- @protected
--- @param data table Данные от анализатора Astra
function BaseMonitor:_process_psi_data(data)
    local name = data.psi
    if name then
        self._psi[name:upper()] = data
    end
end

--- Возвращает закэшированные PSI данные
--- @param table_name string|nil Имя таблицы (например, "PMT"). Если nil, вернет весь кэш.
--- @return table|nil Данные PSI или nil
function BaseMonitor:get_psi(table_name)
    if not self._psi then return nil end
    if table_name then
        return self._psi[table_name:upper()]
    end
    return self._psi
end

--- Очищает кэш PSI данных
--- @protected
function BaseMonitor:_clear_psi()
    self._psi = {}
end

--- Проверяет, прошел ли интервал времени для выполнения проверки
--- @protected
--- @param time_check number Интервал проверки из конфигурации
--- @return boolean true если интервал прошел, иначе false
function BaseMonitor:_should_send(time_check)
    self._force_timer = self._force_timer + 1
    
    if self._check_timer < (time_check or 0) then
        self._check_timer = self._check_timer + 1
        return false
    end
    
    self._check_timer = 0
    return true
end

--- Сбрасывает таймер принудительной отправки
--- @protected
function BaseMonitor:_reset_force_timer()
    self._force_timer = 0
end

--- Возобновляет мониторинг
--- @return boolean Статус выполнения
function BaseMonitor:resume()
    if self._state == BaseMonitor.STATE.STOPPED then
        Logger.error(self._component_name, "[%s] Cannot resume: monitor already stopped", tostring(self._name))
        return false
    end
    self._active = true
    Logger.info(self._component_name, "[%s] Мониторинг возобновлен", tostring(self._name))
    return true
end

return BaseMonitor
