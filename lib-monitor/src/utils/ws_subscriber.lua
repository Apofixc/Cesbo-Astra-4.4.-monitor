-- ===========================================================================
-- Модуль `utils.ws_subscriber`
--
-- Реализует рассылку событий через WebSocket.
-- ===========================================================================

-- 1. Стандартные Lua функции
local pairs = pairs
local pcall = pcall

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "WsSubscriber"

--- @class WsSubscriber
--- @field private clients table<any, boolean> Список активных WebSocket клиентов
--- @field private http_server_instance any Ссылка на экземпляр http_server
local WsSubscriber = {}

local clients = {}
local http_server_instance = nil

--- Обработчик WebSocket соединений (callback для http_websocket).
--- Регистрирует новых клиентов и обрабатывает входящие сообщения.
--- @param server any Экземпляр сервера
--- @param client any Экземпляр клиента (userdata)
--- @param request any Данные запроса (строка сообщения или nil при закрытии)
function WsSubscriber.on_message(server, client, request)
    http_server_instance = server
    if request == nil then
        clients[client] = nil
        return
    end
    if request == "ping" then server:send(client, "pong") return end
    if not clients[client] then
        clients[client] = true
        server:send(client, '{"event":"sys:connected","data":"Добро пожаловать"}')
    end
end

--- Рассылает уже готовый JSON всем подключенным клиентам.
--- Данные оборачиваются в структуру события {event, data}.
--- @param event_type string Тип события
--- @param json_data string JSON-строка с данными
function WsSubscriber.broadcast_raw(event_type, json_data)
    if not http_server_instance or not json_data then return end
    local message = '{"event":"' .. event_type .. '","data":' .. json_data .. '}'
    for client, _ in pairs(clients) do
        pcall(http_server_instance.send, http_server_instance, client, message)
    end
end

return WsSubscriber
