-- ===========================================================================
-- Модуль `repository.channel_repository`
--
-- Репозиторий для управления мониторами каналов.
-- Наследуется от BaseRepository и добавляет специфичную логику поиска
-- каналов по адаптерам и управления зависимыми потоками.
-- ===========================================================================

-- 1. Стандартные Lua функции
local ipairs = _G.ipairs
local pairs = _G.pairs
local pcall = _G.pcall
local table_insert = _G.table.insert
local tostring = _G.tostring
local type = _G.type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local Utils = ModuleManager.get_module("utils")
local BaseRepository = ModuleManager.get_module("core.base_repository")
local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelRepository"

--- Локальная конфигурация модуля (значения по умолчанию)
local _m_config = {
    ChannelMonitorLimit = 200,
}

-- 5. Внутреннее состояние (Private State)
-- (Состояние инкапсулировано в экземпляре ChannelRepository)

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- @class ChannelRepository : BaseRepository
local ChannelRepository = BaseRepository.new(COMPONENT_NAME)

--- Инициализирует подписку на обновление конфигурации
function ChannelRepository:init_config_subscription()
    self:init_base_config_subscription()

    if EventDispatcher then
        local instance = EventDispatcher.get_instance()
        instance:subscribe("config:updated:monitor", function(new_config)
            for k, v in pairs(new_config) do
                _m_config[k] = v
            end
            -- Обновляем лимит в базовом репозитории
            if _m_config.ChannelMonitorLimit then
                self:set_limit(_m_config.ChannelMonitorLimit)
            end
            Logger.info(COMPONENT_NAME, "Конфигурация репозитория каналов обновлена")
        end)
    end
end

--- Хук, вызываемый перед пересозданием монитора.
--- Генерирует событие для перезапуска стрима.
--- @protected
--- @param name string Имя монитора
--- @param reason string Причина ("silence" или "watchdog")
--- @return boolean success
function ChannelRepository:_on_before_recreate(name, reason)
    if reason == "watchdog" or reason == "silence" then
        if EventDispatcher then
            Logger.info(COMPONENT_NAME, "[%s] Запрос на перезапуск стрима (причина: %s)", name, reason)
            EventDispatcher.get_instance():emit("channel:action:recreate", name, reason)
        end
    end
    return true
end

-- ===========================================================================
-- Публичное API: Поиск
-- ===========================================================================

--- Находит все каналы в системе Astra, использующие указанный DVB-адаптер.
--- Проверяет все входы канала.
--- @param adapter_name string Имя адаптера (например, "0" или "0.1")
--- @return table<string, table> Список найденных каналов (имя -> ch_data)
function ChannelRepository:find_by_adapter(adapter_name)
    local result = {}
    local channel_list = ModuleManager.get_global_dependency("channel_list")

    if not channel_list then
        Logger.error(COMPONENT_NAME, "find_by_adapter: зависимость channel_list не найдена")
        return result
    end

    local target_adapter = tostring(adapter_name)
    for _, ch_data in pairs(channel_list) do
        local inputs = ch_data.input
        if type(inputs) == "table" then
            for i = 1, #inputs do
                local input = inputs[i]
                local is_match = false

                if type(input) == "table" then
                    local cfg = input.config
                    if type(cfg) == "table" and cfg.format == "dvb" and tostring(cfg.addr or "") == target_adapter then
                        is_match = true
                    end
                elseif type(input) == "string" then
                    local parsed = Utils.parse_url(input)
                    if parsed and parsed.format == "dvb" and tostring(parsed.addr) == target_adapter then
                        is_match = true
                    end
                end

                if is_match then
                    local name = (type(ch_data.config) == "table") and ch_data.config.name
                    if name then
                        result[name] = ch_data
                    end
                    -- Если нашли совпадение в одном из входов, переходим к следующему каналу
                    break
                end
            end
        end
    end

    return result
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return ChannelRepository
