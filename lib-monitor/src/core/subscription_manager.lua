-- ===========================================================================
-- Модуль `core.subscription_manager`
--
-- Динамическое управление подписками на события мониторинга.
-- Поддерживает HTTP, WebSocket, Console и Lua callback транспорты.
-- Реализует оптимизацию Fast Path, троттлинг, сохранение подписок и повторы.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = _G.type
local tostring = _G.tostring
local string_format = _G.string.format
local pairs = _G.pairs
local table_insert = _G.table.insert
local table_remove = _G.table.remove
local os_clock = _G.os.clock
local pcall = _G.pcall
local setmetatable = _G.setmetatable
local io = _G.io
local math_random = _G.math.random
local math_floor = _G.math.floor
local string_gsub = _G.string.gsub
local table_concat = _G.table.concat

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local FilterEngine = ModuleManager.get_module("utils.filter_engine")
local Wildcard = ModuleManager.get_module("utils.wildcard")
local TablePool = ModuleManager.get_module("table_pool")

-- 3. Глобальные зависимости Astra (Lazy Caching)
local _http_request = nil
local _json_encode = nil
local _json_decode = nil
local _astra_version = nil
local _user_agent = nil

--- Возвращает функцию http_request
--- @return function|nil
local function get_http_request()
    if _http_request then return _http_request end
    _http_request = ModuleManager.get_global_dependency("http_request")
    return _http_request
end

--- Возвращает функцию json.encode
--- @return function|nil
local function get_json_encode()
    if _json_encode then return _json_encode end
    _json_encode = ModuleManager.get_global_dependency("json.encode")
    return _json_encode
end

--- Возвращает функцию json.decode
--- @return function|nil
local function get_json_decode()
    if _json_decode then return _json_decode end
    _json_decode = ModuleManager.get_global_dependency("json.decode")
    return _json_decode
end

--- Возвращает строку User-Agent
--- Оптимизировано: кэширование полной строки заголовка.
--- @return string
local function get_user_agent()
    if _user_agent then return _user_agent end
    if not _astra_version then
        _astra_version = ModuleManager.get_global_dependency("astra.version") or "unknown"
    end
    _user_agent = "User-Agent: Astra v." .. _astra_version
    return _user_agent
end

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SubscriptionManager"
local CONTENT_TYPE = "Content-Type: application/json;charset=utf-8"
local CONNECTION_CLOSE = "Connection: close"
local STORAGE_PATH = "/opt/astra/lib-monitor/subscribers.json"
local MAX_RETRIES = (MonitorConfig and MonitorConfig.MaxRetries) or 5
local RETRY_DELAY = (MonitorConfig and MonitorConfig.RetryDelay) or 5
local HTTP_TIMEOUT = (MonitorConfig and MonitorConfig.HttpTimeout) or 10
local MAX_ROUTE_CACHE_SIZE = (MonitorConfig and MonitorConfig.MaxRouteCacheSize) or 1000
local MAX_RETRY_QUEUE_SIZE = (MonitorConfig and MonitorConfig.MaxRetryQueueSize) or 500

-- 5. Внутреннее состояние (Private State)
--- @class SubscriptionManagerState
--- @field transport_cache table<any, string> Кэш типов транспорта
--- @field plan_cache table<string, table> Кэш планов доставки
local state = {
    transport_cache = {},
    plan_cache = {},
}

--- @class SubscriptionStats
--- @field delivered number Количество успешно доставленных событий
--- @field failed number Количество проваленных доставок
--- @field consecutive_failures number Количество последовательных ошибок

--- @class Subscription
--- @field id string Уникальный идентификатор
--- @field event_type string Тип события или маска
--- @field callback function|table Конфигурация коллбэка
--- @field transport string Тип транспорта (HTTP, WS, CONSOLE, LUA_CALLBACK)
--- @field host_header string|nil Кэшированный заголовок Host (для HTTP)
--- @field filters table Фильтры события
--- @field batch_mode string Режим батчинга (single, array)
--- @field throttle_ms number Троттлинг в мс
--- @field active boolean Флаг активности
--- @field last_event_at number Время последнего события
--- @field stats SubscriptionStats Статистика подписки

--- @class SubscriptionManager
--- @field private subscriptions table<string, table<string, Subscription>> Хранилище подписок
--- @field private stats table Глобальная статистика подписок
--- @field private _matchers table<string, function> Кэш скомпилированных матчеров
--- @field private _route_cache table<string, Subscription[]> Кэш маршрутизации
--- @field private _route_cache_size number Текущий размер кэша маршрутизации
--- @field private _plan_cache table<string, table> Кэш планов доставки (Smart Emit)
--- @field private _save_pending boolean Флаг отложенного сохранения
--- @field private _batch_queues table<string, table> Очереди для пакетной отправки
--- @field private _retry_queue table Очередь на повторную отправку
local SubscriptionManager = {}
SubscriptionManager.__index = SubscriptionManager

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Генерирует уникальный идентификатор (UUID v4) для подписки
--- @private
--- @return string UUID
local function _generate_uuid()
    local template = "xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"
    return (string_gsub(template, "[xy]", function(c)
        local v = (c == "x") and math_random(0, 0xf) or math_random(8, 0xb)
        return string_format("%x", v)
    end))
end

--- Вспомогательная функция для получения JSON из события (Lazy JSON)
--- @private
--- @param event table Объект события
--- @return string|nil JSON-строка
local function _get_event_json(event)
    if not event then return nil end
    
    -- 1. Проверяем кэш в самом объекте события (самый быстрый путь)
    if event.json_cache then return event.json_cache end
    
    local options = event.options
    -- 2. Проверяем кэш в опциях (совместимость)
    if options and options.json_cache then return options.json_cache end

    local encode = get_json_encode()
    if not encode then return nil end

    local json
    if type(event.data) == "string" then
        json = event.data
    else
        local ok, res = pcall(encode, event.data)
        if not ok then
            Logger.error(COMPONENT_NAME, "Ошибка кодирования JSON: %s", tostring(res))
            return nil
        end
        json = res
    end

    -- Сохраняем кэш для повторного использования
    event.json_cache = json
    if options then options.json_cache = json end

    return json
end

--- @type table<string, function> Транспорты для доставки событий
local Transport = {
    --- Доставка через HTTP POST запрос
    --- @param self SubscriptionManager
    --- @param config table Параметры (host, port, path)
    --- @param event table|string Объект события или данные
    --- @param event_type string Тип события
--- @param retry_count? number Текущая попытка повтора
--- @param event_json? string Предварительно подготовленный JSON
    HTTP = function(self, config, event, event_type, retry_count, event_json)
        local request = get_http_request()
        if not request then return false, "http_request недоступен" end

        local encode = get_json_encode()
        local content = event_json or
                        ((type(event) == "table" and event.id) and _get_event_json(event) or
                        ((type(event) == "table") and (encode and encode(event) or nil) or tostring(event)))

        if not content then return false, "ошибка кодирования JSON" end

        retry_count = retry_count or 0

        -- Оптимизация: используем кэшированный заголовок Host если доступен
        local host_header = config._host_header or ("Host: " .. config.host .. ":" .. config.port)

        request({
            host = config.host, port = config.port, path = config.path or "/",
            method = "POST", content = content,
            timeout = HTTP_TIMEOUT,
            headers = {
                get_user_agent(), host_header,
                CONTENT_TYPE, "Content-Length: " .. #content, CONNECTION_CLOSE
            },
            callback = function(s, response)
                -- Ретрай при ошибке соединения (not s) или HTTP 5xx
                local is_error = not s
                if s and response and response.code >= 500 then
                    is_error = true
                end

                if is_error and retry_count < MAX_RETRIES then
                    self:enqueue_retry(config, event, event_type, retry_count, content)
                end
            end
        })
        return true
    end,
    --- Доставка через WebSocket
    --- @param self SubscriptionManager
    --- @param config table Параметры транспорта
    --- @param event table|string Объект события или данные
    --- @param event_type string Тип события
    --- @param event_json? string Предварительно подготовленный JSON
    WS = function(self, config, event, event_type, event_json)
        local WsSubscriber = ModuleManager.get_module("ws_subscriber")
        if WsSubscriber and WsSubscriber.broadcast_raw then
            local encode = get_json_encode()
            local json_data = event_json or
                             ((type(event) == "table" and event.id) and _get_event_json(event) or
                             ((type(event) == "table") and (encode and encode(event) or nil) or event))
            WsSubscriber.broadcast_raw(event_type, json_data)
            return true
        end
        return false, "WsSubscriber недоступен"
    end,
    --- Доставка через вызов Lua функции
    --- @param self SubscriptionManager
    --- @param config table Параметры (callback)
    --- @param event table|string Объект события или данные
    LUA_CALLBACK = function(self, config, event)
        local callback = type(config) == "table" and config.callback or config
        if type(callback) ~= "function" then return false, "некорректный callback" end
        local data = (type(event) == "table" and event.id) and event.data or event
        return pcall(callback, data)
    end,
    --- Вывод события в консоль (лог Astra)
    --- @param self SubscriptionManager
    --- @param config table Параметры транспорта
    --- @param event table|string Объект события или данные
    --- @param event_type string Тип события
    --- @param event_json? string Предварительно подготовленный JSON
    CONSOLE = function(self, config, event, event_type, event_json)
        local encode = get_json_encode()
        local message = event_json or
                        ((type(event) == "table" and event.id) and _get_event_json(event) or
                        ((type(event) == "table") and (encode and encode(event) or nil) or event))
        Logger.info("Консоль", "[СОБЫТИЕ:%s] %s", tostring(event_type), tostring(message))
        return true
    end
}

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Добавляет событие в очередь на повторную отправку.
--- @param config table Параметры транспорта
--- @param event table|string Объект события или данные
--- @param event_type string Тип события
--- @param retry_count number Текущая попытка
--- @param content string Подготовленный JSON
--- @return boolean Статус добавления
function SubscriptionManager:enqueue_retry(config, event, event_type, retry_count, content)
    if #self._retry_queue >= MAX_RETRY_QUEUE_SIZE then
        Logger.warning(COMPONENT_NAME, "Очередь повторов переполнена, событие %s отброшено", event_type)
        return false
    end

    local delay = RETRY_DELAY * (2 ^ retry_count)
    local jitter = math_random() * 2

    local item = TablePool and TablePool.get("retry_item") or {}
    item.config = config
    -- Для ретрая делаем копию данных, если это была таблица из пула
    local retry_data = event
    if type(event) == "table" and event.is_table then
        retry_data = content
    end
    item.data = retry_data
    item.type = event_type
    item.retries = retry_count + 1
    item.time = os_clock() + delay + jitter

    table_insert(self._retry_queue, item)
    return true
end

--- Создает и инициализирует новый экземпляр SubscriptionManager
--- Загружает сохраненные подписки из файла и запускает обработчик повторов
--- @return SubscriptionManager Экземпляр менеджера
function SubscriptionManager.new()
    local self = setmetatable({}, SubscriptionManager)
    self.subscriptions = {} -- [event_type][subscription_id] = sub_data
    self.stats = { total = 0, delivered = 0, failed = 0 }
    self._matchers = {} -- [pattern] = function
    self._route_cache = {} -- [event_type] = { sub1, sub2, ... }
    self._route_cache_size = 0
    self._plan_cache = {} -- [event_type] = { simple_groups = {}, complex_subs = {} }
    self._save_pending = false
    self._batch_queues = {} -- [sub_id] = { events = {}, last_flush = T }
    self._retry_queue = {}
    self:load()
    self:start_retry_processor()
    return self
end

--- Запускает фоновый процесс обработки очереди повторных попыток и отложенного сохранения.
--- @private
function SubscriptionManager:start_retry_processor()
    local Scheduler = ModuleManager.get_module("core.scheduler")
    if not Scheduler then return end

    local scheduler = Scheduler.get_instance()

    -- Задача для повторов и сохранения (раз в секунду)
    scheduler:add_task("subscription_manager_maintenance", function()
        local now = os_clock()

        -- 1. Пакетная отправка (Batch Flush)
        if MonitorConfig and MonitorConfig.BatchEnabled then
            local interval = MonitorConfig.BatchFlushInterval or 0.5
            for sub_id, queue in pairs(self._batch_queues) do
                if #queue.events > 0 and (now - queue.last_flush) >= interval then
                    self:flush_batch(sub_id)
                end
            end
        end

        -- 2. Обработка повторов
        for i = #self._retry_queue, 1, -1 do
            local item = self._retry_queue[i]
            if now >= item.time then
                table_remove(self._retry_queue, i)
                Transport.HTTP(self, item.config, item.data, item.type, item.retries)

                if TablePool then
                    TablePool.release(item, "retry_item")
                end
            end
        end

        -- 3. Отложенное сохранение (Debounced Save)
        if self._save_pending then
            self:save_now()
        end
    end, 1)
end

--- Планирует сохранение подписок (отложенная запись).
function SubscriptionManager:save()
    self._save_pending = true
end

--- Немедленно сохраняет текущие активные подписки в JSON файл.
--- Использует атомарную запись через временный файл.
--- Lua-коллбэки игнорируются при сохранении.
--- @return boolean Статус выполнения
function SubscriptionManager:save_now()
    local encode = get_json_encode()
    if not encode then return false end

    self._save_pending = false
    local data_to_save = {}
    for event_type, subs in pairs(self.subscriptions) do
        data_to_save[event_type] = {}
        for id, sub in pairs(subs) do
            if sub.transport ~= "LUA_CALLBACK" then
                data_to_save[event_type][id] = {
                    callback = sub.callback,
                    filters = sub.filters,
                    batch_mode = sub.batch_mode,
                    throttle_ms = sub.throttle_ms,
                    active = sub.active
                }
            end
        end
    end

    local content = encode(data_to_save)
    if not content then return false end

    -- Атомарная запись через временный файл
    local tmp_path = STORAGE_PATH .. ".tmp"
    local f = io.open(tmp_path, "w")
    if f then
        f:write(content)
        f:close()
        -- В Astra/Linux os.rename атомарен
        local ok, err = os.rename(tmp_path, STORAGE_PATH)
        if not ok then
            Logger.error(COMPONENT_NAME, "Ошибка атомарного сохранения: %s", tostring(err))
            os.remove(tmp_path)
            return false
        end
        return true
    end
    return false
end

--- Загружает подписки из JSON файла и регистрирует их в системе.
--- @private
function SubscriptionManager:load()
    local decode = get_json_decode()
    if not decode then return end

    local f = io.open(STORAGE_PATH, "r")
    if not f then return end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return end
    local data = decode(content)
    if type(data) ~= "table" then return end
    for event_type, subs in pairs(data) do
        if type(subs) == "table" then
            for id, sub_data in pairs(subs) do
                self:subscribe(event_type, sub_data, id)
            end
        end
    end
end

--- Регистрирует новую подписку на события
--- @param event_type string Тип события или маска
--- @param sub_data table|function Данные подписки (callback, filters, throttle_ms) или функция коллбэка
--- @param existing_id? string Использовать существующий ID (для загрузки из файла)
--- @return string|nil ID подписки (UUID) или nil при ошибке
function SubscriptionManager:subscribe(event_type, sub_data, existing_id)
    -- Ограничение размера кэша транспортов для предотвращения утечек
    if not existing_id then
        local count = 0
        for _ in pairs(state.transport_cache) do count = count + 1 end
        if count >= 1000 then state.transport_cache = {} end
    end

    -- Поддержка передачи функции напрямую
    if type(sub_data) == "function" then
        sub_data = { callback = sub_data }
    end

    local transport = self:detect_transport(sub_data.callback)
    if not transport then return nil end

    local sub_id = existing_id or _generate_uuid()
    local filters = sub_data.filters or {}
    local default_batch_mode = (MonitorConfig and MonitorConfig.DefaultBatchMode) or "single"

    -- Предкомпиляция аксессоров для фильтров
    if FilterEngine and filters.conditions then
        for _, cond in pairs(filters.conditions) do
            if cond.field then
                cond.accessor = FilterEngine.compile_accessor(cond.field)
            end
        end
    end

    -- Предварительный расчет сложности и сигнатуры доставки (Smart Emit)
    local is_complex = (filters and (filters.conditions or filters.script)) or
                       (sub_data.throttle_ms and sub_data.throttle_ms > 0) or
                       (sub_data.batch_mode and sub_data.batch_mode ~= "single") or
                       (transport == "LUA_CALLBACK")

    local delivery_sig = nil
    if not is_complex then
        local cb = sub_data.callback
        if transport == "HTTP" then
            delivery_sig = "H:" .. tostring(cb.host) .. ":" .. tostring(cb.port) .. ":" .. tostring(cb.path or "/")
        elseif transport == "WS" then
            delivery_sig = "W"
        elseif transport == "CONSOLE" then
            delivery_sig = "C"
        end
    end

    local subscription = {
        id = sub_id, event_type = event_type, callback = sub_data.callback,
        transport = transport, filters = filters,
        batch_mode = sub_data.batch_mode or default_batch_mode,
        -- throttle_ms: 0 - выключено, >0 - минимальный интервал между событиями
        throttle_ms = sub_data.throttle_ms or 0, active = sub_data.active ~= false,
        last_event_at = 0, stats = { delivered = 0, failed = 0, consecutive_failures = 0 },
        is_complex = is_complex,
        delivery_sig = delivery_sig
    }

    -- Кэширование заголовка Host для HTTP транспорта
    if transport == "HTTP" and type(subscription.callback) == "table" then
        local cb = subscription.callback
        cb._host_header = "Host: " .. tostring(cb.host) .. ":" .. tostring(cb.port)
    end

    if not self.subscriptions[event_type] then
        self.subscriptions[event_type] = {}
        -- Предкомпиляция маски
        if Wildcard then
            self._matchers[event_type] = Wildcard.compile(event_type)
        end
    end
    self.subscriptions[event_type][sub_id] = subscription
    self.stats.total = self.stats.total + 1

    -- Оптимизация: Гранулярный сброс кэша маршрутизации и планов
    if event_type:find("*", 1, true) or event_type:find("?", 1, true) then
        -- Если добавлена маска, нужно проверить все записи в кэше, которые могут ей соответствовать
        local to_remove = {}
        for cached_type, _ in pairs(self._route_cache) do
            if self:match(event_type, cached_type) then
                table_insert(to_remove, cached_type)
            end
        end
        for _, k in pairs(to_remove) do
            self._route_cache[k] = nil
            self._plan_cache[k] = nil
            self._route_cache_size = self._route_cache_size - 1
        end
        -- Сброс дерева решений Wildcard
        if Wildcard and Wildcard.clear_tree then Wildcard.clear_tree() end
    elseif self._route_cache[event_type] then
        self._route_cache[event_type] = nil
        self._plan_cache[event_type] = nil
        self._route_cache_size = self._route_cache_size - 1
    end

    if not existing_id then self:save() end
    return sub_id
end

--- Проверяет соответствие имени события маске.
--- @param pattern string Маска
--- @param name string Имя события
--- @return boolean Результат
function SubscriptionManager:match(pattern, name)
    local matcher = self._matchers[pattern]
    if not matcher and Wildcard and (pattern:find("*", 1, true) or pattern:find("?", 1, true)) then
        matcher = Wildcard.compile(pattern)
        self._matchers[pattern] = matcher -- Кэшируем скомпилированный матчер
    end

    if matcher then return matcher(name) end
    return pattern == name
end

--- Возвращает список подписчиков для указанного типа события, используя кэш.
--- @private
--- @param self SubscriptionManager
--- @param event_type string Тип события
--- @return Subscription[] Список подписчиков
function SubscriptionManager._get_targets(self, event_type)
    local targets = self._route_cache[event_type]
    if targets then return targets end

    -- Ограничение размера кэша для предотвращения утечек памяти
    if self._route_cache_size >= MAX_ROUTE_CACHE_SIZE then
        self._route_cache = {}
        self._route_cache_size = 0
    end

    targets = {}
    -- Оптимизация: использование Decision Tree для поиска всех масок за один проход
    if Wildcard and Wildcard.match_multiple then
        local matched_patterns = Wildcard.match_multiple(event_type, self.subscriptions)
        for _, pattern in ipairs(matched_patterns) do
            local subs = self.subscriptions[pattern]
            if subs then
                for _, sub in pairs(subs) do
                    table_insert(targets, sub)
                end
            end
        end
    else
        -- Fallback на обычный перебор
        for pattern, subs in pairs(self.subscriptions) do
            if self:match(pattern, event_type) then
                for _, sub in pairs(subs) do
                    table_insert(targets, sub)
                end
            end
        end
    end
    self._route_cache[event_type] = targets
    self._route_cache_size = self._route_cache_size + 1
    return targets
end

--- Рассылает объект события всем подписчикам.
--- Оптимизировано: использует DeliveryPlan для ускорения рассылки и мультикастинга.
--- @param event table Объект события (из EventDispatcher)
--- @param now? number Текущее время (опционально, для оптимизации)
--- @return boolean Статус выполнения
function SubscriptionManager:publish_event(event, now)
    now = now or os_clock()
    local event_type = event.type
    local event_data = event.data
    local options = event.options

    -- Защита от "призрачных" вызовов: если монитор-источник уже уничтожен, игнорируем событие
    if options and options.source_monitor then
        local monitor = options.source_monitor
        -- STATE.STOPPED = 3
        if monitor.get_state and monitor:get_state() == 3 then
            return false
        end
    end

    -- Получаем план доставки (Smart Emit)
    local plan = self:get_delivery_plan(event_type)
    if not plan then return false end

    local delivered, failed = 0, 0
    local event_json = _get_event_json(event)

    -- 1. Fast Path: Мультикастинг для простых групп
    if plan.total_simple > 0 then
        self:multicast_direct(plan, event_type, event_data, now, event_json)
    end

    -- 2. Обработка сложных подписчиков (фильтры, троттлинг, батчинг)
    local complex_subs = plan.complex_subs
    local batch_enabled = MonitorConfig and MonitorConfig.BatchEnabled

    for i = 1, #complex_subs do
        local sub = complex_subs[i]
        if sub.active then
            local should_send = true
            -- Троттлинг
            if sub.throttle_ms > 0 and (now - sub.last_event_at) < (sub.throttle_ms / 1000) then
                should_send = false
            end
            -- Фильтрация
            if should_send and sub.filters and (sub.filters.conditions or sub.filters.script) then
                if FilterEngine and not FilterEngine.match(event_data, sub.filters, sub.id) then
                    should_send = false
                end
            end

            if should_send then
                -- Пакетная отправка (Batching)
                if batch_enabled and
                   (sub.transport == "HTTP" or sub.transport == "WS") and
                   sub.batch_mode ~= "single"
                then
                    self:add_to_batch(sub, event)
                    delivered = delivered + 1
                else
                    -- Обычная отправка
                    local success, _ = Transport[sub.transport](self, sub.callback, event, event_type, nil, event_json)
                    if success then
                        delivered = delivered + 1
                        sub.stats.delivered = sub.stats.delivered + 1
                        sub.stats.consecutive_failures = 0
                        sub.last_event_at = now
                    else
                        failed = failed + 1
                        sub.stats.failed = sub.stats.failed + 1
                        sub.stats.consecutive_failures = (sub.stats.consecutive_failures or 0) + 1

                        -- Circuit Breaker: Автоматическое удаление "мертвых" подписчиков
                        if sub.stats.consecutive_failures >= 20 then
                            Logger.error(COMPONENT_NAME, 
                                "Circuit Breaker: Удаление мертвого подписчика %s (%s) после %d ошибок", 
                                sub.id, sub.transport, sub.stats.consecutive_failures)
                            self:unsubscribe(sub.id)
                        end
                    end
                end
            end
        end
    end

    self.stats.delivered = self.stats.delivered + delivered
    self.stats.failed = self.stats.failed + failed
    return true
end

--- Отправляет событие конкретному подписчику по его ID.
--- Используется для инициализации (LVC) или отладки.
--- Оптимизировано: использует Hybrid LVC (предварительно закодированный JSON).
--- @param sub_id string ID подписки
--- @param event_type string Имя события
--- @param event_entry table Запись LVC (содержит .data и .json)
--- @return boolean Статус выполнения
function SubscriptionManager:publish_to_single(sub_id, event_type, event_entry)
    for _, subs in pairs(self.subscriptions) do
        local sub = subs[sub_id]
        if sub then
            local transport = sub.transport
            local payload = event_entry.data
            local event_json = event_entry.json

            -- Smart Packaging для LVC: если режим array, оборачиваем в массив
            if sub.batch_mode == "array" then
                if transport == "LUA_CALLBACK" then
                    payload = { event_entry.data }
                else
                    -- Дешевая упаковка JSON в массив без перекодирования
                    event_json = "[" .. (event_entry.json or "null") .. "]"
                    payload = event_json
                end
            end

            Transport[transport](self, sub.callback, payload, event_type, nil, event_json)
            return true
        end
    end
    return false
end

--- Определяет тип транспорта на основе конфигурации callback.
--- Оптимизировано: использование кэша для предотвращения повторного разбора.
--- @param cfg function|table Конфигурация коллбэка или функция
--- @return string|nil Тип транспорта (HTTP, WS, CONSOLE, LUA_CALLBACK)
function SubscriptionManager:detect_transport(cfg)
    local cached = state.transport_cache[cfg]
    if cached then return cached end

    local t
    if type(cfg) == "function" then
        t = "LUA_CALLBACK"
    elseif type(cfg) == "table" then
        t = cfg.type and cfg.type:upper()
        if not (t == "HTTP" or t == "WS" or t == "CONSOLE" or t == "LUA_CALLBACK") then
            if cfg.host and cfg.port then
                t = "HTTP"
            else
                t = nil
            end
        end
    end

    if t then state.transport_cache[cfg] = t end
    return t
end

--- Добавляет событие в пакетную очередь подписчика
--- Оптимизация: сохраняем уже готовую JSON-строку для предотвращения повреждения данных
--- и ускорения финальной сборки батча.
--- @param sub table Объект подписки
--- @param event table Объект события
function SubscriptionManager:add_to_batch(sub, event)
    local sub_id = sub.id
    if not self._batch_queues[sub_id] then
        local q = TablePool and TablePool.get("batch_queue") or {}
        q.events = q.events or {}
        q.last_flush = os_clock()
        self._batch_queues[sub_id] = q
    end

    local queue = self._batch_queues[sub_id]

    -- Получаем JSON события (используем кэш, если он есть)
    local event_json = _get_event_json(event)
    if event_json then
        table_insert(queue.events, event_json)
    end

    -- Smart Flush: немедленный сброс для критических событий (Priority 1-2)
    local is_high_priority = event.priority and event.priority <= 2
    local max_size = MonitorConfig and MonitorConfig.BatchMaxSize or 50

    if is_high_priority or #queue.events >= max_size then
        self:flush_batch(sub_id)
    end
end

--- Принудительно отправляет накопленную пачку событий.
--- Оптимизация: сборка батча через table.concat без повторного json.encode.
--- @param sub_id string ID подписки
function SubscriptionManager:flush_batch(sub_id)
    local queue = self._batch_queues[sub_id]
    if not queue or #queue.events == 0 then return end

    -- Находим объект подписки
    local sub = nil
    for _, subs in pairs(self.subscriptions) do
        if subs[sub_id] then sub = subs[sub_id]; break end
    end
    if not sub then
        if TablePool then TablePool.release(queue, "batch_queue") end
        self._batch_queues[sub_id] = nil
        return
    end

    local events_json = queue.events
    local count = #events_json

    -- Сборка финального JSON
    local final_json
    if count == 1 and sub.batch_mode ~= "array" then
        final_json = events_json[1]
    else
        final_json = "[" .. table.concat(events_json, ",") .. "]"
    end

    -- Очищаем массив событий (но не саму таблицу очереди)
    for i = 1, count do events_json[i] = nil end
    queue.last_flush = os_clock()

    -- Отправляем готовую строку. Транспорт HTTP/WS поддерживает передачу event_json.
    -- Для LUA_CALLBACK придется декодировать обратно, но батчинг обычно используется для внешних систем.
    --- @type string|table|nil
    local payload
    if sub.transport == "LUA_CALLBACK" then
        local decode = get_json_decode()
        payload = decode and decode(final_json) or nil
    else
        payload = final_json
    end

    local success, _ = Transport[sub.transport](self, sub.callback, payload, sub.event_type, nil, final_json)
    if success then
        sub.stats.delivered = sub.stats.delivered + count
        sub.last_event_at = queue.last_flush
    end
end

--- Останавливает менеджер подписок, сбрасывает батчи и удаляет задачи из планировщика.
function SubscriptionManager:shutdown()
    local Scheduler = ModuleManager.get_module("core.scheduler")
    if Scheduler then
        Scheduler.get_instance():remove_task("subscription_manager_maintenance")
    end

    -- Сброс всех накопленных батчей перед выходом
    if MonitorConfig and MonitorConfig.BatchEnabled then
        for sub_id, _ in pairs(self._batch_queues) do
            self:flush_batch(sub_id)
        end
    end

    -- Финальное сохранение, если оно требовалось
    if self._save_pending then
        self:save_now()
    end

    Logger.info(COMPONENT_NAME, "Менеджер подписок остановлен")
end

--- Удаляет подписку по её ID и сохраняет изменения в файл.
--- @param sub_id string ID подписки
--- @return boolean Статус выполнения
function SubscriptionManager:unsubscribe(sub_id)
    if self._batch_queues[sub_id] then
        if TablePool then TablePool.release(self._batch_queues[sub_id], "batch_queue") end
        self._batch_queues[sub_id] = nil
    end

    -- Очистка состояния фильтров (FilterEngine)
    if FilterEngine and FilterEngine.clear_state then
        FilterEngine.clear_state(sub_id)
    end

    for event_type, subs in pairs(self.subscriptions) do
        local sub = subs[sub_id]
        if sub then
            subs[sub_id] = nil
            self.stats.total = self.stats.total - 1

            -- Если подписок на этот тип больше нет, удаляем матчер
            if not next(subs) then
                self.subscriptions[event_type] = nil
                self._matchers[event_type] = nil
            end

            -- Оптимизация: Проактивное обновление планов при удалении
            local is_wildcard = event_type:find("*", 1, true) or event_type:find("?", 1, true)

            if is_wildcard then
                local to_remove = {}
                for cached_type, _ in pairs(self._route_cache) do
                    if self:match(event_type, cached_type) then
                        table_insert(to_remove, cached_type)
                    end
                end
                for _, k in pairs(to_remove) do
                    self._route_cache[k] = nil
                    self._plan_cache[k] = nil
                    self._route_cache_size = self._route_cache_size - 1
                end
                if Wildcard and Wildcard.clear_tree then Wildcard.clear_tree() end
            else
                -- Для прямой подписки сбрасываем кэш плана, чтобы он пересчитался при следующем запросе
                -- (Удаление из вложенных структур групп сложнее, чем просто сброс кэша одного типа)
                self._route_cache[event_type] = nil
                self._plan_cache[event_type] = nil
                self._route_cache_size = self._route_cache_size - 1
            end

            self:save()
            return true
        end
    end
    return false
end

--- Возвращает план доставки для указанного типа события.
--- План разделяет подписчиков на "простые" группы (для мультикастинга) и "сложные" (индивидуальные).
--- @param event_type string Тип события
--- @return table|nil План доставки или nil если подписчиков нет
function SubscriptionManager:get_delivery_plan(event_type)
    local plan = self._plan_cache[event_type]
    if plan then return plan end

    -- Если плана нет в кэше, получаем список всех целей
    local targets = self:_get_targets(event_type)

    if not targets or #targets == 0 then return nil end

    plan = {
        simple_groups = {}, -- [signature] = { transport, config, subs = {sub1, ...} }
        complex_subs = {},  -- { sub1, sub2, ... }
        has_complex = false,
        total_simple = 0
    }

    for i = 1, #targets do
        local sub = targets[i]
        if sub.active then
            if sub.is_complex then
                table_insert(plan.complex_subs, sub)
                plan.has_complex = true
            else
                local sig = sub.delivery_sig
                if sig then
                    if not plan.simple_groups[sig] then
                        plan.simple_groups[sig] = {
                            transport = sub.transport,
                            config = sub.callback,
                            subs = {}
                        }
                    end
                    table_insert(plan.simple_groups[sig].subs, sub)
                    plan.total_simple = plan.total_simple + 1
                else
                    -- Fallback если сигнатура не была рассчитана
                    table_insert(plan.complex_subs, sub)
                    plan.has_complex = true
                end
            end
        end
    end

    self._plan_cache[event_type] = plan
    return plan
end

--- Выполняет прямую рассылку события по группам простых подписчиков.
--- Оптимизировано: JSON кодируется один раз.
--- @param plan table План доставки (из get_delivery_plan)
--- @param event_type string Тип события
--- @param event_data table|string Данные события
--- @param now number Текущее время
--- @param event_json? string Предварительно подготовленный JSON
function SubscriptionManager:multicast_direct(plan, event_type, event_data, now, event_json)
    if not event_json then
        local encode = get_json_encode()
        -- Кодируем JSON один раз для всех групп
        if type(event_data) == "table" then
            local ok, res = pcall(encode, event_data)
            if ok then event_json = res end
        else
            event_json = tostring(event_data)
        end
    end

    if not event_json then return end

    for _, group in pairs(plan.simple_groups) do
        local transport_func = Transport[group.transport]
        if transport_func then
            -- Отправляем группе. Так как подписчики простые, мы просто вызываем транспорт.
            -- Статистику обновляем для каждого подписчика в группе.
            local success, _ = transport_func(self, group.config, event_data, event_type, nil, event_json)
            
            local subs = group.subs
            for i = 1, #subs do
                local sub = subs[i]
                if success then
                    sub.stats.delivered = sub.stats.delivered + 1
                    sub.stats.consecutive_failures = 0
                    sub.last_event_at = now
                else
                    sub.stats.failed = sub.stats.failed + 1
                    sub.stats.consecutive_failures = (sub.stats.consecutive_failures or 0) + 1

                    -- Circuit Breaker: Автоматическое удаление "мертвых" подписчиков
                    if sub.stats.consecutive_failures >= 20 then
                        Logger.error(COMPONENT_NAME, 
                            "Circuit Breaker (Multicast): Удаление мертвого подписчика %s (%s) после %d ошибок", 
                            sub.id, sub.transport, sub.stats.consecutive_failures)
                        self:unsubscribe(sub.id)
                    end
                end
            end
            
            if success then
                self.stats.delivered = self.stats.delivered + #subs
            else
                self.stats.failed = self.stats.failed + #subs
            end
        end
    end
end

--- Проверяет наличие активных подписок на указанный тип события.
--- @param event_type string Тип события
--- @return boolean true если есть хотя бы один активный подписчик
function SubscriptionManager:has_subscriptions(event_type)
    -- Проверка через кэш маршрутизации (самый быстрый путь)
    local targets = self:_get_targets(event_type)
    for i = 1, #targets do
        if targets[i].active then return true end
    end
    return false
end

--- Возвращает список всех активных подписок в системе.
--- @return table<string, table> Таблица подписок
function SubscriptionManager:get_all_subscriptions()
    local res = {}
    for _, subs in pairs(self.subscriptions) do
        for id, sub in pairs(subs) do res[id] = sub end
    end
    return res
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

-- Регистрация пулов при загрузке модуля
local tp = ModuleManager.get_module("table_pool")
if tp then
    tp.register_type("retry_item")
    tp.register_type("batch_queue")
end

return SubscriptionManager
