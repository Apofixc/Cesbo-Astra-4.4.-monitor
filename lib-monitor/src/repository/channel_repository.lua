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

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- (Загружаются динамически в методах для поддержки горячей перезагрузки)

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

--- Вспомогательная функция для безопасного запуска одного канала
--- @param conf table Конфигурация канала
--- @return boolean success
local function _safe_make_stream(conf)
    local Channel = ModuleManager.get_module("channel")
    if not Channel then return false end
    
    local name = conf.name or "Unknown"
    Logger.debug(COMPONENT_NAME, "Попытка запуска канала: %s", name)

    local ok, res = pcall(Channel.make_stream, conf)
    if ok and res then
        Logger.debug(COMPONENT_NAME, "Канал %s успешно запущен", name)
        return true
    end

    Logger.error(COMPONENT_NAME, "Ошибка при запуске канала %s: %s", 
        name, tostring(res or "unknown error"))
    return false
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- @class ChannelRepository : BaseRepository
local ChannelRepository = BaseRepository.new(COMPONENT_NAME)

--- Инициализирует подписку на обновление конфигурации
function ChannelRepository:init_config_subscription()
    self:init_base_config_subscription()

    local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
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
--- Выполняет перезапуск стрима в Astra.
--- @protected
--- @param name string Имя монитора
--- @param reason string Причина ("silence" или "watchdog")
--- @return boolean success
function ChannelRepository:_on_before_recreate(name, reason)
    if reason == "watchdog" or reason == "silence" then
        local Channel = ModuleManager.get_module("channel")
        if Channel then
            Logger.info(COMPONENT_NAME, "[%s] Перезапуск стрима (причина: %s)", name, reason)
            local conf = Channel.kill_stream(name)
            if conf then
                return Channel.make_stream(conf) ~= nil
            end
        end
    end
    return true
end

-- ===========================================================================
-- Публичное API: Управление зависимыми каналами
-- ===========================================================================

--- Останавливает все каналы, использующие указанные адаптеры.
--- @param adapter_list table Список имен адаптеров
--- @return table Список сохраненных конфигураций каналов
function ChannelRepository:stop_dependent_channels(adapter_list)
    local Channel = ModuleManager.get_module("channel")
    local saved_configs = {}
    if not Channel or type(adapter_list) ~= "table" then return saved_configs end

    -- 1. Собираем все уникальные зависимые каналы для всех адаптеров
    local affected_channels = {}
    for _, adapter_name in ipairs(adapter_list) do
        local deps = self:find_by_adapter(adapter_name)
        for name, ch_data in pairs(deps) do
            if not affected_channels[name] then
                affected_channels[name] = true
            end
        end
    end

    -- 2. Останавливаем каждый канал один раз
    for name, _ in pairs(affected_channels) do
        local ch_config = Channel.kill_stream(name)
        if ch_config then
            table_insert(saved_configs, ch_config)
        end
    end

    return saved_configs
end

--- Запускает каналы на основе предоставленных конфигураций.
--- @param configs table Список конфигураций каналов
function ChannelRepository:start_dependent_channels(configs)
    if not configs or type(configs) ~= "table" then return end

    local total = #configs
    if total == 0 then return end

    Logger.info(COMPONENT_NAME, "Запуск %d зависимых каналов...", total)
    local success_count = 0

    for _, conf in ipairs(configs) do
        if _safe_make_stream(conf) then
            success_count = success_count + 1
        end
    end

    if success_count == total then
        Logger.info(COMPONENT_NAME, "Все зависимые каналы (%d/%d) успешно запущены", success_count, total)
    else
        Logger.warning(COMPONENT_NAME, "Запуск зависимых каналов завершен частично: %d из %d успешно",
            success_count, total)
    end
end

--- Выполняет транзакционную переконфигурацию каналов.
--- @param adapter_list table Список имен адаптеров
--- @param callback function Функция, выполняемая между остановкой и запуском каналов
--- @param channel_updates? table Таблица обновлений конфигураций каналов (name -> input)
--- @return boolean success
function ChannelRepository:reconfigure_channels(adapter_list, callback, channel_updates)
    if type(adapter_list) ~= "table" or type(callback) ~= "function" then return false end

    -- 1. Останавливаем все зависимые каналы
    local saved_configs = self:stop_dependent_channels(adapter_list)

    -- 2. Выполняем инфраструктурные действия (рестарт адаптеров)
    local ok, err = pcall(callback)
    if not ok then
        Logger.error(COMPONENT_NAME, "Ошибка в callback переконфигурации: %s", tostring(err))
    end

    -- 3. Применяем обновления конфигураций (если есть)
    if channel_updates and type(channel_updates) == "table" then
        for _, conf in ipairs(saved_configs) do
            local new_input = channel_updates[conf.name]
            if new_input then
                conf.input = new_input
            end
        end
    end

    -- 4. Запускаем каналы обратно
    self:start_dependent_channels(saved_configs)

    return ok
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
