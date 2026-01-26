-- ===========================================================================
-- Модуль `utils.ws_subscriber`
--
-- Реализует рассылку событий через протокол WebSocket. Обеспечивает управление
-- списком активных клиентов и потоковую передачу данных в реальном времени.
-- ===========================================================================

-- 1. Стандартные Lua функции
local pairs = pairs
local pcall = pcall

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Scheduler = ModuleManager.get_module("core.scheduler")
local EventDispatcher = nil -- Кэшируется при инициализации подписок

-- 3. Глобальные зависимости Astra
-- (Модуль не использует внешние зависимости Astra)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "WsSubscriber"

-- 5. Внутреннее состояние (Private State)
--- @class WsClientInfo
--- @field error_count number Счетчик ошибок
--- @field batch boolean Включен ли режим батчинга
--- @field buffer table|nil Буфер для накопления событий

--- @class WsSubscriberState
--- @field clients table<userdata, WsClientInfo> Список активных WebSocket клиентов
--- @field http_server_instance any Ссылка на экземпляр http_server
--- @field is_task_running boolean Флаг запущенной задачи планировщика
local state = {
    clients = {},
    http_server_instance = nil,
    is_task_running = false,
}

--- Локальная конфигурация модуля (значения по умолчанию)
local _m_config = {
    WsBatchInterval = 0.05,
}

--- @class WsSubscriber
local WsSubscriber = {}

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Сбрасывает накопленные буферы для всех клиентов с включенным батчингом
--- @private
local function _flush_buffers()
    local server = state.http_server_instance
    if not server then return end

    local send = server.send
    local table_concat = _G.table.concat

    for client, info in pairs(state.clients) do
        if info.batch and info.buffer and #info.buffer > 0 then
            local message = "[" .. table_concat(info.buffer, ",") .. "]"
            -- Очистка буфера
            for i = 1, #info.buffer do info.buffer[i] = nil end

            local ok = pcall(send, server, client, message)
            if not ok then
                info.error_count = info.error_count + 1
                if info.error_count >= 5 then
                    state.clients[client] = nil
                    if server.close then pcall(server.close, server, client) end
                end
            else
                info.error_count = 0
            end
        end
    end
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Инициализирует подписку на обновление конфигурации
function WsSubscriber.init_config_subscription()
    if not EventDispatcher then
        EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
    end

    if EventDispatcher then
        local instance = EventDispatcher.get_instance()
        instance:subscribe("config:updated:batch", function(new_config)
            if new_config.WsBatchInterval and new_config.WsBatchInterval ~= _m_config.WsBatchInterval then
                _m_config.WsBatchInterval = new_config.WsBatchInterval
                if Scheduler and state.is_task_running then
                    Scheduler.get_instance():set_task_interval("ws_subscriber_flush", _m_config.WsBatchInterval)
                end
                if Logger then
                    Logger.debug(COMPONENT_NAME, "Интервал батчинга WebSocket обновлен: %.3f", _m_config.WsBatchInterval)
                end
            end
        end)
    end
end

--- Инициализирует модуль и привязывает его к экземпляру HTTP-сервера
--- @param server any Экземпляр сервера Astra http_server
--- @return boolean Статус инициализации
function WsSubscriber.init(server)
    if not server then
        if Logger then Logger.error(COMPONENT_NAME, "Попытка инициализации с пустым сервером") end
        return false
    end
    state.http_server_instance = server

    -- Запуск задачи планировщика для сброса батчей (раз в 50мс)
    if not state.is_task_running then
        if Scheduler then
            local interval = _m_config.WsBatchInterval
            Scheduler.get_instance():add_task("ws_subscriber_flush", _flush_buffers, interval)
            state.is_task_running = true
        end
    end

    return true
end

--- Очищает список клиентов и сбрасывает ссылку на сервер
function WsSubscriber.clear()
    state.clients = {}
    state.http_server_instance = nil
end

--- Останавливает модуль и удаляет задачи из планировщика.
function WsSubscriber.shutdown()
    if state.is_task_running then
        if Scheduler then
            Scheduler.get_instance():remove_task("ws_subscriber_flush")
        end
        state.is_task_running = false
    end
    WsSubscriber.clear()
    if Logger then
        Logger.info(COMPONENT_NAME, "Модуль WebSocket подписчиков остановлен")
    end
end

--- Обработчик WebSocket соединений (callback для http_websocket)
--- Регистрирует новых клиентов и обрабатывает входящие сообщения
--- @param server any Экземпляр сервера
--- @param client userdata Экземпляр клиента (userdata)
--- @param request string|nil Данные запроса (строка сообщения или nil при закрытии)
function WsSubscriber.on_message(server, client, request)
    -- Автоматическое обновление ссылки на сервер при активности
    if not state.http_server_instance then
        WsSubscriber.init(server)
    end

    -- Если request == nil, значит соединение закрыто
    if request == nil then
        state.clients[client] = nil
        return
    end

    -- Регистрация нового клиента при первом сообщении
    local info = state.clients[client]
    if not info then
        info = { error_count = 0, batch = false, buffer = nil }
        state.clients[client] = info
        pcall(server.send, server, client, '{"event":"sys:connected","data":"Добро пожаловать"}')
    end

    -- Обработка системных сообщений
    if request == "ping" then
        pcall(server.send, server, client, "pong")
        return
    end

    -- Команда включения батчинга: {"command":"batch","enable":true}
    if request:find('"command"%s*:%s*"batch"') then
        local enable = request:find('"enable"%s*:%s*true') ~= nil
        info.batch = enable
        if enable then
            info.buffer = info.buffer or {}
        end
        pcall(server.send, server, client, '{"event":"sys:batch","data":' .. tostring(enable) .. '}')
    end
end

--- Рассылает уже готовый JSON всем подключенным клиентам.
--- Данные оборачиваются в структуру события {event, data}.
--- Оптимизировано: поддержка батчинга и кэширование сообщения.
--- @param event_type string Тип события
--- @param json_data string JSON-строка с данными
function WsSubscriber.broadcast_raw(event_type, json_data)
    local server = state.http_server_instance
    if not server or not json_data then return end

    local clients = state.clients
    if not next(clients) then return end

    local message = nil -- Ленивая сборка сообщения
    local send = server.send
    local close = server.close
    local table_insert = _G.table.insert

    for client, info in pairs(clients) do
        if info.batch then
            -- Режим батчинга: добавляем в буфер
            message = message or ('{"event":"' .. event_type .. '","data":' .. json_data .. '}')
            table_insert(info.buffer, message)

            -- Если буфер слишком большой, сбрасываем немедленно
            if #info.buffer >= 100 then
                local batch_msg = "[" .. _G.table.concat(info.buffer, ",") .. "]"
                for i = 1, #info.buffer do info.buffer[i] = nil end
                local ok = pcall(send, server, client, batch_msg)
                if not ok then info.error_count = info.error_count + 1 end
            end
        else
            -- Обычный режим: немедленная отправка
            message = message or ('{"event":"' .. event_type .. '","data":' .. json_data .. '}')
            local ok = pcall(send, server, client, message)
            if not ok then
                info.error_count = info.error_count + 1
                if info.error_count >= 5 then
                    state.clients[client] = nil
                    if close then pcall(close, server, client) end
                end
            else
                info.error_count = 0
            end
        end
    end
end

--- Возвращает количество активных WebSocket клиентов
--- @return number Количество клиентов
function WsSubscriber.get_clients_count()
    local count = 0
    for _ in pairs(state.clients) do count = count + 1 end
    return count
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return WsSubscriber
