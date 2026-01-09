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
local WsSubscriber = {}

local clients = {}
local http_server_instance = nil

--- Обработчик WebSocket соединений
function WsSubscriber.on_message(server, client, request)
    http_server_instance = server
    if request == nil then
        clients[client] = nil
        return
    end
    if request == "ping" then server:send(client, "pong") return end
    if not clients[client] then
        clients[client] = true
        server:send(client, '{"event":"sys:connected","data":"Welcome"}')
    end
end

--- Рассылает уже готовый JSON всем клиентам
function WsSubscriber.broadcast_raw(event_type, json_data)
    if not http_server_instance or not json_data then return end
    local message = '{"event":"' .. event_type .. '","data":' .. json_data .. '}'
    for client, _ in pairs(clients) do
        pcall(http_server_instance.send, http_server_instance, client, message)
    end
end

return WsSubscriber
