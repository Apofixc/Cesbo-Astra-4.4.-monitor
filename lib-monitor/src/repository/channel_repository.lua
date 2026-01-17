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
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local channel_list = ModuleManager.get_global_dependency("channel_list")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelRepository"

-- ===========================================================================
-- Внутренние функции (Private)
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
-- Инициализация репозитория
-- ===========================================================================

--- @class ChannelRepository : BaseRepository
--- @field private _watchdog_retries table<string, number> Счетчики попыток перезапуска
local ChannelRepository = BaseRepository.new(COMPONENT_NAME)
ChannelRepository._watchdog_retries = {}

--- Проверка Watchdog для канала
--- @protected
function ChannelRepository:_check_monitor_watchdog(name, monitor, status, now)
    local watchdog_enabled = MonitorConfig and MonitorConfig.WatchdogEnabled
    if not watchdog_enabled then return end

    -- 1. Проверка Bitrate (No Data)
    local bitrate = status.bitrate or 0
    local is_failed = (bitrate == 0)
    
    -- 2. Проверка Scrambled (CAS Error)
    if not is_failed and status.scrambled then
        is_failed = true
    end

    if is_failed then
        local retries = (self._watchdog_retries[name] or 0) + 1
        local max_retries = (MonitorConfig and MonitorConfig.WatchdogMaxRetries) or 3
        
        if retries <= max_retries then
            Logger.warn(COMPONENT_NAME, "[%s] Watchdog: обнаружен сбой, попытка перезапуска %d/%d", 
                name, retries, max_retries)
            
            self._watchdog_retries[name] = retries
            
            local Channel = ModuleManager.get_module("channel")
            if Channel then
                local conf = Channel.kill_stream(name)
                if conf then
                    Channel.make_stream(conf)
                end
            end
        else
            Logger.error(COMPONENT_NAME, "[%s] Watchdog: превышен лимит перезапусков. Блокировка.", name)
            -- Генерируем критическое событие
            self:_emit_event("sys:watchdog_failed", name, { retries = retries - 1 })
        end
    else
        -- Сброс счетчика при стабильной работе
        if self._watchdog_retries[name] then
            self._watchdog_retries[name] = nil
            Logger.info(COMPONENT_NAME, "[%s] Watchdog: работа стабилизировалась, счетчик сброшен", name)
        end
    end
end

-- ===========================================================================
-- Публичное API: Управление зависимыми каналами
-- ===========================================================================

--- Останавливает все каналы, использующие указанный адаптер.
--- @param adapter_name string Имя адаптера
--- @return table Список сохраненных конфигураций каналов
function ChannelRepository:stop_dependent_channels(adapter_name)
    local Channel = ModuleManager.get_module("channel")
    local saved_configs = {}
    if not Channel then return saved_configs end

    local dependent_channels = self:find_by_adapter(adapter_name)
    for name, _ in pairs(dependent_channels) do
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
        Logger.warn(COMPONENT_NAME, "Запуск зависимых каналов завершен частично: %d из %d успешно", 
            success_count, total)
    end
end

-- ===========================================================================
-- Публичное API: Поиск
-- ===========================================================================

--- Находит все каналы в системе Astra, использующие указанный DVB-адаптер
--- @param adapter_name string Имя адаптера (например, "0" или "0.1")
--- @return table<string, table> Список найденных каналов (имя -> ch_data)
function ChannelRepository:find_by_adapter(adapter_name)
    local result = {}

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
                
                -- В Astra ch_data.input[i] может быть строкой URL или таблицей с полем config
                local cfg
                if type(input) == "table" then
                    cfg = input.config
                elseif type(input) == "string" then
                    -- Используем системный парсинг URL
                    local parsed = Utils.parse_url(input)
                    if parsed and parsed.format == "dvb" and tostring(parsed.addr) == target_adapter then
                        local name = (type(ch_data.config) == "table") and ch_data.config.name
                        if name then result[name] = ch_data end
                        break
                    end
                end

                if type(cfg) == "table" and cfg.format == "dvb" and tostring(cfg.addr or "") == target_adapter then
                    local name = (type(ch_data.config) == "table") and ch_data.config.name
                    if name then
                        result[name] = ch_data
                    end
                    break
                end
            end
        end
    end
    
    return result
end

return ChannelRepository
