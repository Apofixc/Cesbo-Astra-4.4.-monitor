-- ===========================================================================
-- Модуль `repository.dvb_repository`
--
-- Репозиторий для управления мониторами DVB-адаптеров.
-- Наследуется от BaseRepository.
-- ===========================================================================

-- 1. Стандартные Lua функции
-- (Нет прямых зависимостей)

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local BaseRepository = ModuleManager.get_module("core.base_repository")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbRepository"

-- 5. Внутреннее состояние (Private State)
-- (Состояние инкапсулировано в экземпляре DvbRepository)

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

-- (Внутренние функции будут ниже)

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- @class DvbRepository : BaseRepository
local DvbRepository = BaseRepository.new(COMPONENT_NAME)

--- Хук, вызываемый перед пересозданием монитора.
--- Выполняет перезапуск DVB-адаптера в Astra.
--- @protected
--- @param name string Имя монитора
--- @param reason string Причина ("silence" или "watchdog")
--- @return boolean success
function DvbRepository:_on_before_recreate(name, reason)
    if reason == "watchdog" or reason == "silence" then
        local Adapter = ModuleManager.get_module("adapter")
        if Adapter and Adapter.restart_dvb_monitor then
            Logger.info(COMPONENT_NAME, "[%s] Перезапуск адаптера (причина: %s)", name, reason)
            Adapter.restart_dvb_monitor(name)
        end
    end
    return true
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return DvbRepository
