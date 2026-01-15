-- ===========================================================================
-- Модуль `utils.ws_subscriber`
--
-- Реализует рассылку событий через протокол WebSocket. Обеспечивает управление
-- списком активных клиентов и потоковую передачу данных в реальном времени.
-- ===========================================================================

-- 1. Стандартные Lua функции
local pairs = pairs
local pcall = pcall
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "WsSubscriber"

--- @class WsSubscriber
--- @field private clients table<userdata, boolean> Список активных WebSocket клиентов
--- @field private http_server_instance any Ссылка на экземпляр http_server
local WsSubscriber = {}

local clients = {}
local http_server_instance = nil

--- Инициализирует модуль и привязывает его к экземпляру HTTP-сервера.
--- @param server any Экземпляр сервера Astra http_server
function WsSubscriber.init(server)
    if not server then
        Logger.error(COMPONENT_NAME, "Попытка инициализации с пустым сервером")
        return false
    end
    http_server_instance = server
    return true
end

--- Очищает список клиентов и сбрасывает ссылку на сервер.
function WsSubscriber.clear()
    clients = {}
    http_server_instance = nil
end

--- Обработчик WebSocket соединений (callback для http_websocket).
--- Регистрирует новых клиентов и обрабатывает входящие сообщения.
--- @param server any Экземпляр сервера
--- @param client userdata Экземпляр клиента (userdata)
--- @param request string|nil Данные запроса (строка сообщения или nil при закрытии)
function WsSubscriber.on_message(server, client, request)
    -- Автоматическое обновление ссылки на сервер при активности
    if not http_server_instance then
        http_server_instance = server
    end

    -- Если request == nil, значит соединение закрыто
    if request == nil then
        if clients[client] then
            clients[client] = nil
        end
        return
    end

    -- Регистрация нового клиента при первом сообщении
    if not clients[client] then
        clients[client] = true
        pcall(server.send, server, client, '{"event":"sys:connected","data":"Добро пожаловать"}')
    end

    -- Обработка системных сообщений
    if request == "ping" then
        pcall(server.send, server, client, "pong")
        return
    end
end

--- Рассылает уже готовый JSON всем подключенным клиентам.
--- Данные оборачиваются в структуру события {event, data}.
--- @param event_type string Тип события
--- @param json_data string JSON-строка с данными
function WsSubscriber.broadcast_raw(event_type, json_data)
    if not http_server_instance or not json_data then
        return
    end

    -- Оптимизация: Проверяем наличие клиентов перед сборкой сообщения
    if not next(clients) then return end

    local message = '{"event":"' .. event_type .. '","data":' .. json_data .. '}'
    
    for client, _ in pairs(clients) do
        local ok, err = pcall(http_server_instance.send, http_server_instance, client, message)
        if not ok then
            -- Если отправка не удалась, вероятно клиент отключился некорректно
            clients[client] = nil
            Logger.debug(COMPONENT_NAME, "Ошибка отправки клиенту WS (удален): %s", tostring(err))
        end
    end
end

--- Возвращает количество активных WebSocket клиентов.
--- @return number
function WsSubscriber.get_clients_count()
    local count = 0
    for _ in pairs(clients) do count = count + 1 end
    return count
end

return WsSubscriber
