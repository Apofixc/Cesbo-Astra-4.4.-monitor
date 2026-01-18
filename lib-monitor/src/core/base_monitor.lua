-- ===========================================================================
-- Модуль `core.base_monitor`
--
-- Базовый класс для всех мониторов в системе. Предоставляет общую логику
-- управления состоянием, таймерами, кэшированием JSON и публикацией событий.
-- ===========================================================================

-- 1. Стандартные Lua функции
local setmetatable = _G.setmetatable
local tostring = _G.tostring
local os_time = _G.os.time
local collectgarbage = _G.collectgarbage
local math_max = _G.math.max

-- 2. Функции из ModuleManager.get_module()
local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local TablePool = ModuleManager.get_module("utils.table_pool")

-- 3. Глобальные зависимости Astra
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- ===========================================================================
-- Константы и конфигурации
-- ===========================================================================

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
--- @field protected _load_shedding_active boolean Флаг активного снижения нагрузки
--- @field protected _original_time_check number Оригинальный интервал проверки
--- @field protected _resource_sub_id string|nil ID подписки на системные ресурсы
local BaseMonitor = {}
BaseMonitor.__index = BaseMonitor

BaseMonitor.STATE = {
    IDLE = 1,
    RUNNING = 2,
    STOPPED = 3,
}

-- Кэш для ключей конфигурации (предотвращает лишние аллокации строк в gsub)
-- Ключ: prefix .. param_name
local CONFIG_KEY_CACHE = {}

-- ===========================================================================
-- Внутреннее состояние (Private State)
-- ===========================================================================

-- (Для классов состояние инкапсулировано в экземпляре, создаваемом в .new)

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

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

    -- ВАЖНО: Мы НЕ меняем self._config, так как это эталон.
    -- Изменения применяются только через хук в рабочую копию (astra_conf).
    self:_on_config_updated(key, result)
    return true
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

--- Сбрасывает кэш JSON-представления.
--- Вызывается при обновлении данных монитора.
--- @protected
function BaseMonitor:_clear_json_cache()
    self._json_cache = nil
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

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Конструктор базового монитора
--- @param config table Конфигурация монитора
--- @param component_name string Имя компонента для логирования
--- @return BaseMonitor Экземпляр базового монитора
function BaseMonitor.new(config, component_name)
    --- @type BaseMonitor
    local self = setmetatable({}, BaseMonitor)

    -- 1. Конфигурация и идентификация
    self._config = config
    self._name = self._config.name or "Unknown"
    self._component_name = component_name or "BaseMonitor"

    -- 2. Состояние процесса
    self._active = false
    self._state = BaseMonitor.STATE.IDLE
    self._instance = nil

    -- 3. Таймеры и интервалы
    self._force_interval = (MonitorConfig and MonitorConfig.ForceSendInterval) or 300
    self._force_timer = self._force_interval -- Сразу готов к отправке
    self._check_timer = 0
    self._last_update = os_time()

    -- 4. Кэш и вспомогательные объекты
    self._json_cache = nil
    self._current_method = nil
    self._psi = {}
    self._table_pool = TablePool

    -- 5. Адаптивность
    self._load_shedding_active = false
    self._original_time_check = 0

    -- Подписка на события снижения нагрузки
    if EventDispatcher then
        local dispatcher = EventDispatcher.get_instance()
        self._resource_sub_id = dispatcher:subscribe("sys:resource_warning", function(data)
            if data.type == "cpu" then
                if data.status == "critical" then
                    self:_enable_load_shedding()
                elseif data.status == "ok" then
                    self:_disable_load_shedding()
                end
            end
        end)
    end

    return self
end

--- Включает режим снижения нагрузки
--- @protected
function BaseMonitor:_enable_load_shedding()
    if self._load_shedding_active then return end
    
    self._load_shedding_active = true
    self._original_time_check = self._config.time_check or 0
    
    -- 1. Увеличиваем интервал проверки в 3 раза (минимум до 5 секунд)
    local new_check = math_max(5, self._original_time_check * 3)
    -- ВАЖНО: Мы НЕ меняем self._config, изменения только в runtime через хук.

    Logger.warn(self._component_name, "[%s] Load Shedding: интервал проверки увеличен %d -> %d",
        tostring(self._name), self._original_time_check, new_check)
    
    self:_on_config_updated("time_check", new_check)
end

--- Выключает режим снижения нагрузки
--- @protected
function BaseMonitor:_disable_load_shedding()
    if not self._load_shedding_active then return end
    
    self._load_shedding_active = false
    -- ВАЖНО: Мы НЕ меняем self._config, изменения только в runtime через хук.

    Logger.info(self._component_name, "[%s] Load Shedding: интервал проверки восстановлен до %d",
        tostring(self._name), self._original_time_check)
    
    self:_on_config_updated("time_check", self._original_time_check)
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

--- Публикует данные через EventDispatcher.
--- Использует пул для таблицы опций (Zero-Allocation Path).
--- @param data table|string Данные события
--- @param event_type string Тип события
--- @param is_table? boolean [Флаг, что данные из пула таблиц]
function BaseMonitor:publish(data, event_type, is_table)
    local dispatcher = EventDispatcher and EventDispatcher.get_instance()
    if not dispatcher then return end

    -- Берем таблицу опций из пула для минимизации нагрузки на GC
    local options = self:get_table_from_pool("event_options")
    options.is_table = is_table
    options.source = self._name
    options.source_monitor = self
    options.json_cache = self._json_cache

    -- Метка для автоматического возврата в пул при глубокой очистке события
    options.__pool_type = "event_options"

    dispatcher:emit_safe(event_type, data, nil, options)
end

--- Возвращает актуальные данные в виде таблицы (сырые данные).
--- Должен быть переопределен в наследниках.
--- @return table|nil Таблица данных
function BaseMonitor:get_status_table()
    return nil
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
    -- Отписка от системных событий для предотвращения утечек памяти
    if self._resource_sub_id and EventDispatcher then
        EventDispatcher.get_instance():unsubscribe(self._resource_sub_id)
        self._resource_sub_id = nil
    end

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

--- Вызывается при обновлении конфигурации.
--- Должен быть переопределен в наследниках для синхронизации внутреннего состояния.
--- @protected
--- @param key string Ключ параметра
--- @param value any Новое значение
function BaseMonitor:_on_config_updated(key, value)
    -- Виртуальный метод
end

--- Возвращает данные о состоянии здоровья монитора (программный слой)
--- @return table Данные о состоянии (state, active, last_update)
function BaseMonitor:get_software_status()
    return {
        state = self._state,
        active = self._active,
        last_update = self._last_update
    }
end

--- Проверяет функциональное здоровье монитора (инфраструктурный слой)
--- Должен быть переопределен в наследниках (например, проверка битрейта или Lock).
--- @return boolean|nil is_healthy true если всё в порядке, false если обнаружен сбой, nil если проверка не применима
function BaseMonitor:check_infrastructure_health()
    return nil
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

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

-- Регистрация пулов при загрузке модуля
local tp = ModuleManager.get_module("utils.table_pool")
if tp then
    tp.register_type("generic")
    tp.register_type("event_options")
end

return BaseMonitor
