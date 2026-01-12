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
local os_time = _G.os.time
local pcall = _G.pcall
local setmetatable = _G.setmetatable
local io = _G.io
local math_random = _G.math.random
local math_floor = _G.math.floor
local string_gsub = _G.string.gsub

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local FilterEngine = ModuleManager.get_module("utils.filter_engine")
local Wildcard = ModuleManager.get_module("utils.wildcard")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local http_request = ModuleManager.get_global_dependency("http_request")
local astra_version = ModuleManager.get_global_dependency("astra.version")
local json_encode = ModuleManager.get_global_dependency("json.encode")
local json_decode = ModuleManager.get_global_dependency("json.decode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "SubscriptionManager"
local USER_AGENT = "User-Agent: Astra v." .. (astra_version or "unknown")
local CONTENT_TYPE = "Content-Type: application/json;charset=utf-8"
local STORAGE_PATH = "/opt/astra/lib-monitor/subscribers.json"
local MAX_RETRIES = 5
local RETRY_DELAY = 5
local HTTP_TIMEOUT = (MonitorConfig and MonitorConfig.HttpTimeout) or 10
local MAX_ROUTE_CACHE_SIZE = 1000

--- @class SubscriptionManager
--- @field private subscriptions table<string, table<string, table>> Хранилище подписок по типам событий
--- @field private stats table Глобальная статистика подписок
--- @field private _matchers table<string, function> Кэш скомпилированных матчеров
--- @field private _route_cache table<string, table<number, table>> Кэш маршрутизации
--- @field private _save_pending boolean Флаг отложенного сохранения
--- @field private _batch_queues table<string, table> Очереди для пакетной отправки
local SubscriptionManager = {}
SubscriptionManager.__index = SubscriptionManager

-- Очередь на повторную отправку
local retry_queue = {}

--- Генерирует уникальный идентификатор (UUID v4) для подписки.
--- @return string UUID
local function generate_uuid()
    local template ='xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx'
    return (string_gsub(template, '[xy]', function (c)
        local v = (c == 'x') and math_random(0, 0xf) or math_random(8, 0xb)
        return string_format('%x', v)
    end))
end

-- Максимальный размер очереди повторов
local MAX_RETRY_QUEUE_SIZE = 500

--- Вспомогательная функция для получения JSON из события (Lazy JSON)
--- @param event table Объект события
--- @return string|nil JSON-строка
local function get_event_json(event)
    if not event then return nil end
    if event.json_cache then return event.json_cache end

    if type(event.data) == "string" then
        event.json_cache = event.data
    else
        event.json_cache = json_encode(event.data)
    end
    return event.json_cache
end

--- @type table<string, function> Транспорты для доставки событий
local Transport = {
    --- Доставка через HTTP POST запрос
    --- @param config table Параметры (host, port, path)
    --- @param event table|string Объект события или данные
    --- @param event_type string Тип события
    --- @param retry_count? number [Текущая попытка повтора]
    --- @param event_json? string [Предварительно подготовленный JSON]
    HTTP = function(config, event, event_type, retry_count, event_json)
        if not http_request then return false, "http_request недоступен" end

        local content = event_json or
                        ((type(event) == "table" and event.id) and get_event_json(event) or
                        ((type(event) == "table") and json_encode(event) or tostring(event)))

        if not content then return false, "ошибка кодирования JSON" end

        retry_count = retry_count or 0

        http_request({
            host = config.host, port = config.port, path = config.path or "/",
            method = "POST", content = content,
            timeout = HTTP_TIMEOUT,
            headers = {
                USER_AGENT, "Host: " .. config.host .. ":" .. config.port,
                CONTENT_TYPE, "Content-Length: " .. #content, "Connection: close"
            },
            callback = function(s, r)
                if not s and retry_count < MAX_RETRIES then
                    -- Для ретрая делаем копию данных, если это была таблица из пула
                    local retry_data = event
                    if type(event) == "table" and event.is_table then
                        -- Если это событие с таблицей из пула, к этому моменту таблица может быть уже возвращена в пул.
                        -- Поэтому для ретрая используем уже готовый JSON.
                        retry_data = content
                    end

                    if #retry_queue < MAX_RETRY_QUEUE_SIZE then
                        local delay = math_floor(RETRY_DELAY * (2 ^ retry_count))
                        local jitter = math_random(0, 2)
                        table_insert(retry_queue, {
                            config = config, data = retry_data, type = event_type,
                            retries = retry_count + 1, time = os_time() + delay + jitter
                        })
                    else
                        Logger.warn(COMPONENT_NAME, "Очередь повторов переполнена, событие %s отброшено", event_type)
                    end
                end
            end
        })
        return true
    end,
    --- Доставка через WebSocket
    --- @param config table Параметры транспорта
    --- @param event table|string Объект события или данные
    --- @param event_type string Тип события
    --- @param event_json? string [Предварительно подготовленный JSON]
    WS = function(config, event, event_type, event_json)
        local WsSubscriber = ModuleManager.get_module("ws_subscriber")
        if WsSubscriber and WsSubscriber.broadcast_raw then
            local json_data = event_json or
                             ((type(event) == "table" and event.id) and get_event_json(event) or
                             ((type(event) == "table") and json_encode(event) or event))
            WsSubscriber.broadcast_raw(event_type, json_data)
            return true
        end
        return false, "WsSubscriber недоступен"
    end,
    --- Доставка через вызов Lua функции
    --- @param config table Параметры (callback)
    --- @param event table|string Объект события или данные
    LUA_CALLBACK = function(config, event)
        local callback = type(config) == "table" and config.callback or config
        if type(callback) ~= "function" then return false, "некорректный callback" end
        local data = (type(event) == "table" and event.id) and event.data or event
        return pcall(callback, data)
    end,
    --- Вывод события в консоль (лог Astra)
    --- @param config table Параметры транспорта
    --- @param event table|string Объект события или данные
    --- @param event_type string Тип события
    --- @param event_json? string [Предварительно подготовленный JSON]
    CONSOLE = function(config, event, event_type, event_json)
        local message = event_json or
                        ((type(event) == "table" and event.id) and get_event_json(event) or
                        ((type(event) == "table") and json_encode(event) or event))
        Logger.info("Консоль", "[СОБЫТИЕ:%s] %s", tostring(event_type), tostring(message))
        return true
    end
}

--- Создает и инициализирует новый экземпляр SubscriptionManager.
--- Загружает сохраненные подписки из файла и запускает обработчик повторов.
--- @return SubscriptionManager Экземпляр менеджера
function SubscriptionManager.new()
    local self = setmetatable({}, SubscriptionManager)
    self.subscriptions = {} -- [event_type][subscription_id] = sub_data
    self.stats = { total = 0, delivered = 0, failed = 0 }
    self._matchers = {} -- [pattern] = function
    self._route_cache = {} -- [event_type] = { sub1, sub2, ... }
    self._save_pending = false
    self._batch_queues = {} -- [sub_id] = { events = {}, last_flush = T }
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
        local now = os_time()

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
        for i = #retry_queue, 1, -1 do
            local item = retry_queue[i]
            if now >= item.time then
                table_remove(retry_queue, i)
                Transport.HTTP(item.config, item.data, item.type, item.retries)
            end
        end

        -- 2. Отложенное сохранение (Debounced Save)
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

    local content = json_encode(data_to_save)
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
    local f = io.open(STORAGE_PATH, "r")
    if not f then return end
    local content = f:read("*all")
    f:close()
    if not content or content == "" then return end
    local data = json_decode(content)
    if type(data) ~= "table" then return end
    for event_type, subs in pairs(data) do
        for id, sub_data in pairs(subs) do
            self:subscribe(event_type, sub_data, id)
        end
    end
end

--- Регистрирует новую подписку на события.
--- @param event_type string Тип события или маска
--- @param sub_data table Данные подписки (callback, filters, throttle_ms)
--- @param existing_id? string [Использовать существующий ID (для загрузки из файла)]
--- @return string|nil ID подписки (UUID) или nil при ошибке
function SubscriptionManager:subscribe(event_type, sub_data, existing_id)
    local transport = self:detect_transport(sub_data.callback)
    if not transport then return nil end

    local sub_id = existing_id or generate_uuid()
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

    local subscription = {
        id = sub_id, event_type = event_type, callback = sub_data.callback,
        transport = transport, filters = filters,
        batch_mode = sub_data.batch_mode or default_batch_mode,
        -- throttle_ms: 0 - выключено, >0 - минимальный интервал между событиями
        throttle_ms = sub_data.throttle_ms or 0, active = sub_data.active ~= false,
        last_event_at = 0, stats = { delivered = 0, failed = 0 }
    }

    if not self.subscriptions[event_type] then
        self.subscriptions[event_type] = {}
        -- Предкомпиляция маски
        if Wildcard then
            self._matchers[event_type] = Wildcard.compile(event_type)
        end
    end
    self.subscriptions[event_type][sub_id] = subscription
    self.stats.total = self.stats.total + 1

    -- Оптимизация: Гранулярный сброс кэша маршрутизации
    if event_type:find("*") then
        self._route_cache = {}
    else
        self._route_cache[event_type] = nil
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
    if matcher then return matcher(name) end
    return pattern == name
end

--- Рассылает событие всем подписчикам (устаревший метод).
--- @param event_type string Точное имя события
--- @param event_data table Данные события
--- @return number, number Количество успешно доставленных и проваленных уведомлений
function SubscriptionManager:publish(event_type, event_data)
    return self:publish_event({
        type = event_type,
        data = event_data,
        timestamp = os_time()
    })
end

--- Рассылает объект события всем подписчикам.
--- @param event table Объект события (из EventDispatcher)
--- @return number, number Количество успешно доставленных и проваленных уведомлений
function SubscriptionManager:publish_event(event)
    local delivered, failed = 0, 0
    local now = os_time()
    local event_type = event.type
    local event_data = event.data
    local event_json = nil -- Кэш JSON для текущей рассылки

    -- Оптимизация: Fast Path через кэш маршрутизации
    local targets = self._route_cache[event_type]
    if not targets then
        -- Ограничение размера кэша для предотвращения утечек памяти
        local cache_count = 0
        for _ in pairs(self._route_cache) do cache_count = cache_count + 1 end
        if cache_count >= MAX_ROUTE_CACHE_SIZE then
            self._route_cache = {}
        end

        targets = {}
        for pattern, subs in pairs(self.subscriptions) do
            if self:match(pattern, event_type) then
                for _, sub in pairs(subs) do
                    table_insert(targets, sub)
                end
            end
        end
        self._route_cache[event_type] = targets
    end

    for i = 1, #targets do
        local sub = targets[i]
        if sub.active then
            local should_send = true
            if sub.throttle_ms > 0 and (now - sub.last_event_at) < (sub.throttle_ms / 1000) then
                should_send = false
            end
            if should_send and sub.filters and next(sub.filters) ~= nil then
                if FilterEngine and not FilterEngine.match(event_data, sub.filters, sub.id) then
                    should_send = false
                end
            end
            if should_send then
                -- Пакетная отправка (Batching)
                if MonitorConfig and MonitorConfig.BatchEnabled and
                   (sub.transport == "HTTP" or sub.transport == "WS") and
                   sub.batch_mode ~= "single"
                then
                    self:add_to_batch(sub, event)
                    delivered = delivered + 1 -- Считаем как доставленное в очередь
                else
                    -- Обычная немедленная отправка
                    if sub.transport ~= "LUA_CALLBACK" and not event_json then
                        event_json = get_event_json(event)
                    end

                    local success, _ = Transport[sub.transport](sub.callback, event, event_type, nil, event_json)
                    if success then
                        delivered = delivered + 1
                        sub.stats.delivered = sub.stats.delivered + 1
                        sub.last_event_at = now
                    else
                        failed = failed + 1
                        sub.stats.failed = sub.stats.failed + 1
                    end
                end
            end
        end
    end
    self.stats.delivered = self.stats.delivered + delivered
    self.stats.failed = self.stats.failed + failed
    return delivered, failed
end

--- Отправляет событие конкретному подписчику по его ID.
--- Используется для инициализации (LVC) или отладки.
--- @param sub_id string ID подписки
--- @param event_type string Имя события
--- @param event_data table Данные события
--- @return boolean Статус выполнения
function SubscriptionManager:publish_to_single(sub_id, event_type, event_data)
    for _, subs in pairs(self.subscriptions) do
        local sub = subs[sub_id]
        if sub then
            -- Smart Packaging для LVC: если режим array, оборачиваем в массив
            local payload = event_data
            if sub.batch_mode == "array" then
                payload = { event_data }
            end

            -- Для одиночной отправки (LVC) готовим JSON если нужно
            local event_json = nil
            if sub.transport ~= "LUA_CALLBACK" then
                event_json = (type(payload) == "table") and json_encode(payload) or tostring(payload)
            end
            Transport[sub.transport](sub.callback, payload, event_type, nil, event_json)
            return true
        end
    end
    return false
end

--- Определяет тип транспорта на основе конфигурации callback.
--- @param cfg function|table Конфигурация коллбэка или функция
--- @return string|nil Тип транспорта (HTTP, WS, CONSOLE, LUA_CALLBACK)
function SubscriptionManager:detect_transport(cfg)
    if type(cfg) == "function" then return "LUA_CALLBACK" end
    if type(cfg) == "table" then
        local t = cfg.type and cfg.type:upper()
        if t == "HTTP" or t == "WS" or t == "CONSOLE" or t == "LUA_CALLBACK" then return t end
        if cfg.host and cfg.port then return "HTTP" end
    end
    return nil
end

--- Добавляет событие в пакетную очередь подписчика.
--- Оптимизация: сохраняем уже готовую JSON-строку для предотвращения повреждения данных
--- и ускорения финальной сборки батча.
--- @param sub table Объект подписки
--- @param event table Объект события
function SubscriptionManager:add_to_batch(sub, event)
    local sub_id = sub.id
    if not self._batch_queues[sub_id] then
        self._batch_queues[sub_id] = { events = {}, last_flush = os_time() }
    end

    local queue = self._batch_queues[sub_id]
    
    -- Получаем JSON события (используем кэш, если он есть)
    local event_json = get_event_json(event)
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
    if not sub then self._batch_queues[sub_id] = nil; return end

    local events_json = queue.events
    local count = #events_json
    queue.events = {}
    queue.last_flush = os_time()

    -- Сборка финального JSON
    local final_json
    if count == 1 and sub.batch_mode ~= "array" then
        final_json = events_json[1]
    else
        final_json = "[" .. table.concat(events_json, ",") .. "]"
    end

    -- Отправляем готовую строку. Транспорт HTTP/WS поддерживает передачу event_json.
    -- Для LUA_CALLBACK придется декодировать обратно, но батчинг обычно используется для внешних систем.
    local payload = final_json
    if sub.transport == "LUA_CALLBACK" then
        payload = json_decode(final_json)
    end

    local success, _ = Transport[sub.transport](sub.callback, payload, sub.event_type, nil, final_json)
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
    self._batch_queues[sub_id] = nil

    -- Очистка состояния фильтров (FilterEngine)
    if FilterEngine and FilterEngine.clear_state then
        FilterEngine.clear_state(sub_id)
    end

    for event_type, subs in pairs(self.subscriptions) do
        if subs[sub_id] then
            subs[sub_id] = nil
            self.stats.total = self.stats.total - 1

            -- Если подписок на этот тип больше нет, удаляем матчер
            if not next(subs) then
                self.subscriptions[event_type] = nil
                self._matchers[event_type] = nil
            end

            -- Оптимизация: Гранулярный сброс кэша маршрутизации
            -- Вместо полной очистки сбрасываем только затронутый тип события
            -- и все типы, если это была маска (для простоты)
            if event_type:find("*") then
                self._route_cache = {}
            else
                self._route_cache[event_type] = nil
            end

            self:save()
            return true
        end
    end
    return false
end

--- Проверяет наличие активных подписок на указанный тип события.
--- @param event_type string Тип события
--- @return boolean true если есть хотя бы один активный подписчик
function SubscriptionManager:has_subscriptions(event_type)
    -- Проверка через кэш маршрутизации (самый быстрый путь)
    local targets = self._route_cache[event_type]
    if targets then
        for i = 1, #targets do
            if targets[i].active then return true end
        end
        return false
    end

    -- Если в кэше нет, проверяем все паттерны
    for pattern, subs in pairs(self.subscriptions) do
        if self:match(pattern, event_type) then
            for _, sub in pairs(subs) do
                if sub.active then return true end
            end
        end
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

return SubscriptionManager
