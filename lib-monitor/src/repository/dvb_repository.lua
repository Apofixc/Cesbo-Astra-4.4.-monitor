-- ===========================================================================
-- Модуль `repository.dvb_repository`
--
-- Репозиторий для управления мониторами DVB-адаптеров.
-- Наследуется от BaseRepository.
-- ===========================================================================

-- 1. Стандартные Lua функции

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local BaseRepository = ModuleManager.get_module("core.base_repository")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- ===========================================================================
-- Константы и конфигурации
-- ===========================================================================

local COMPONENT_NAME = "DvbRepository"

-- ===========================================================================
-- Инициализация репозитория
-- ===========================================================================

--- @class DvbRepository : BaseRepository
--- @field private _watchdog_retries table<string, number> Счетчики попыток перезапуска
local DvbRepository = BaseRepository.new(COMPONENT_NAME)
DvbRepository._watchdog_retries = {}

--- Проверка Watchdog для DVB-адаптера
--- @protected
function DvbRepository:_check_monitor_watchdog(name, monitor, status, now)
    local watchdog_enabled = MonitorConfig and MonitorConfig.WatchdogEnabled
    if not watchdog_enabled then return end

    -- Проверка Lock
    local has_lock = status.status and bit32.band(status.status, 0x10) ~= 0
    
    if not has_lock then
        local retries = (self._watchdog_retries[name] or 0) + 1
        local max_retries = (MonitorConfig and MonitorConfig.WatchdogMaxRetries) or 3
        
        if retries <= max_retries then
            Logger.warn(COMPONENT_NAME, "[%s] Watchdog: потерян Lock, попытка перезапуска %d/%d", 
                name, retries, max_retries)
            
            self._watchdog_retries[name] = retries
            
            local Adapter = ModuleManager.get_module("adapter")
            if Adapter and Adapter.restart then
                Adapter.restart(name)
            end
        else
            Logger.error(COMPONENT_NAME, "[%s] Watchdog: превышен лимит перезапусков адаптера. Блокировка.", name)
            self:_emit_event("sys:watchdog_failed", name, { retries = retries - 1 })
        end
    else
        if self._watchdog_retries[name] then
            self._watchdog_retries[name] = nil
            Logger.info(COMPONENT_NAME, "[%s] Watchdog: Lock восстановлен, счетчик сброшен", name)
        end
    end
end

return DvbRepository
