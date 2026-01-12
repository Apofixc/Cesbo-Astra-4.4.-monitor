--- @class BaseMonitor
--- @field protected _name string Технический идентификатор монитора
--- @field protected _config table Конфигурация монитора
--- @field protected _component_name string Имя компонента для логирования
--- @field protected _active boolean Флаг активности мониторинга
--- @field protected _state number Текущее состояние (IDLE, RUNNING, STOPPED)
--- @field protected _instance any|nil Экземпляр Astra (анализатор или тюнер)
--- @field protected _json_cache string|nil Кэш последнего отправленного JSON
--- @field protected _current_method function|nil Прямая ссылка на метод сравнения
--- @field protected _psi table|nil Кэш PSI данных
--- @field protected _check_timer number Таймер интервала проверки
--- @field protected _force_timer number Таймер принудительной отправки статуса
--- @field protected _force_interval number Интервал принудительной отправки
--- @field protected _last_update number Время последнего обновления данных
--- @field protected _table_pool table|nil Прямая ссылка на TablePool (для удобства)
local BaseMonitor = {}
BaseMonitor.__index = BaseMonitor

-- 1. Стандартные Lua функции
local setmetatable = setmetatable
local tostring = tostring
local os_time = os.time
local collectgarbage = collectgarbage

-- 2. Функции из ModuleManager.get_module()
local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local TablePool = ModuleManager.get_module("utils.table_pool")

-- 3. Глобальные зависимости Astra
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы
BaseMonitor.STATE = {
    IDLE = 1,
    RUNNING = 2,
    STOPPED = 3,
}

-- Кэш для ключей конфигурации (предотвращает лишние аллокации строк в gsub)
-- Ключ: prefix .. param_name
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
    self._current_method = nil
    self._psi = {}
    self._check_timer = 0
    self._force_interval = (MonitorConfig and MonitorConfig.ForceSendInterval) or 300
    self._force_timer = self._force_interval -- Сразу готов к отправке
    self._last_update = os_time()
    self._table_pool = TablePool
    return self
end

--- Возвращает таблицу из пула указанного типа.
--- Если пул пуст, создает новую таблицу.
--- @param type_name? string [Тип пула (например, "report", "event"). По умолчанию "generic"]
--- @return table Свободная таблица
function BaseMonitor:get_table_from_pool(type_name)
    if self._table_pool then
        return self._table_pool.get(type_name)
    end
    return {}
end

--- Возвращает таблицу в пул для повторного использования.
--- Перед возвратом таблица полностью очищается.
--- @param t table Таблица для возврата
--- @param type_name? string [Тип пула. По умолчанию "generic"]
--- @param deep? boolean [Флаг глубокой очистки. По умолчанию false]
function BaseMonitor:return_table_to_pool(t, type_name, deep)
    if self._table_pool then
        self._table_pool.release(t, type_name, deep)
    end
end

--- Вспомогательная функция для установки параметра конфигурации
--- @protected
--- @param param_name string Имя параметра (с префиксом)
--- @param value any Значение
--- @param prefix string Префикс для удаления (например, "dvb_" или "channel_")
--- @return boolean Статус выполнения
function BaseMonitor:_set_config_param(param_name, value, prefix)
    if not self._config then return false end

    local result
    if Utils and Utils.validate_monitor_param then
        result = Utils.validate_monitor_param(param_name, value)
    else
        -- Fallback если Utils недоступен
        result = value
    end

    if result == nil then
        Logger.error(self._component_name, "[%s] Некорректное значение параметра для %s: %s",
            tostring(self._name), param_name, tostring(value))
        return false
    end

    local cache_id = prefix .. param_name
    local key = CONFIG_KEY_CACHE[cache_id]
    if not key then
        -- Оптимизация: используем string.sub если префикс в начале, это быстрее gsub
        if param_name:sub(1, #prefix) == prefix then
            key = param_name:sub(#prefix + 1)
        else
            key = param_name:gsub(prefix, "")
        end
        CONFIG_KEY_CACHE[cache_id] = key
    end

    self._config[key] = result
    return true
end

--- Публикует данные через EventDispatcher.
--- Теперь принимает таблицу и поддерживает ленивую сериализацию.
--- Использует emit_safe для предотвращения сбоев монитора при ошибках в шине событий.
--- @param data table|string Данные события
--- @param event_type string Тип события
--- @param is_table? boolean [Флаг, что данные из пула таблиц]
function BaseMonitor:publish(data, event_type, is_table)
    local dispatcher = EventDispatcher and EventDispatcher.get_instance()
    if dispatcher then
        dispatcher:emit_safe(event_type, data, nil, {
            is_table = is_table,
            source = self._name,
            json_cache = self._json_cache -- Передаем горячий кэш, если он есть
        })
    end
end

--- Возвращает актуальные данные в виде таблицы (сырые данные).
--- Должен быть переопределен в наследниках.
--- @return table|nil Таблица данных
function BaseMonitor:get_status_table()
    return nil
end

--- Обновляет JSON-кэш на основе предоставленных данных.
--- @protected
--- @param data table Данные для сериализации
function BaseMonitor:_refresh_cache(data)
    if not data then return end
    if json_encode then
        self._json_cache = json_encode(data)
    else
        self._json_cache = tostring(data)
    end
end

--- Возвращает актуальные данные в виде JSON-строки.
--- Гарантирует возврат актуальной строки (из кэша или создав её).
--- @return string|nil JSON-строка
function BaseMonitor:get_status_json()
    if self._json_cache then return self._json_cache end

    local data = self:get_status_table()
    if not data then return nil end

    self:_refresh_cache(data)
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

--- Полностью очищает базовое состояние монитора.
--- Вызывается в конце методов destroy наследников.
function BaseMonitor:destroy()
    self._active = false
    self._state = BaseMonitor.STATE.STOPPED
    self._instance = nil
    self._config = nil
    self._name = nil
    self._component_name = nil
    self._json_cache = nil
    self._current_method = nil
    self._psi = nil
    self._check_timer = nil
    self._force_timer = nil
    self._force_interval = nil
    self._last_update = nil
    self._table_pool = nil

    -- Согласно astra-api-usage.md: ручное управление памятью обязательно
    -- после остановки монитора или закрытия тяжелых модулей.
    collectgarbage()
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

--- Проверяет, прошел ли интервал времени для выполнения проверки.
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


--- Проверяет, пора ли выполнять принудительную отправку данных
--- @protected
--- @return boolean true если пора, иначе false
function BaseMonitor:_is_force()
    return self._force_timer >= self._force_interval
end

--- Сбрасывает таймер принудительной отправки
--- @protected
function BaseMonitor:_reset_force_timer()
    self._force_timer = 0
    self._last_update = os_time()
end

--- Возвращает данные о состоянии здоровья монитора
--- @return table Данные о состоянии (state, active, last_update)
function BaseMonitor:health_check()
    return {
        state = self._state,
        active = self._active,
        last_update = self._last_update
    }
end

--- Возобновляет мониторинг
--- @return boolean Статус выполнения
function BaseMonitor:resume()
    if self._state == BaseMonitor.STATE.STOPPED then
        Logger.error(self._component_name, "[%s] Не удалось возобновить: монитор остановлен", tostring(self._name))
        return false
    end
    self._active = true
    Logger.info(self._component_name, "[%s] Мониторинг возобновлен", tostring(self._name))
    return true
end

return BaseMonitor
