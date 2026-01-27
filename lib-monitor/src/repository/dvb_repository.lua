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
local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbRepository"

--- Локальная конфигурация модуля (значения по умолчанию)
local _m_config = {
    DvbMonitorLimit = 20,
}

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

--- Инициализирует подписку на обновление конфигурации
function DvbRepository:init_config_subscription()
    self:init_base_config_subscription()

    local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")
    if EventDispatcher then
        local instance = EventDispatcher.get_instance()
        instance:subscribe("config:updated:monitor", function(new_config)
            for k, v in pairs(new_config) do
                _m_config[k] = v
            end
            -- Обновляем лимит в базовом репозитории
            if _m_config.DvbMonitorLimit then
                self:set_limit(_m_config.DvbMonitorLimit)
            end
            Logger.info(COMPONENT_NAME, "Конфигурация репозитория DVB обновлена")
        end)
    end
end

--- Хук, вызываемый перед пересозданием монитора.
--- Генерирует событие для перезапуска DVB-адаптера.
--- @protected
--- @param name string Имя монитора
--- @param reason string Причина ("silence" или "watchdog")
--- @return boolean success
function DvbRepository:_on_before_recreate(name, reason)
    if reason == "watchdog" or reason == "silence" then
        if EventDispatcher then
            Logger.info(COMPONENT_NAME, "[%s] Запрос на перезапуск адаптера (причина: %s)", name, reason)
            EventDispatcher.get_instance():emit("adapter:action:restart", name, reason)
        end
    end
    return true
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return DvbRepository
