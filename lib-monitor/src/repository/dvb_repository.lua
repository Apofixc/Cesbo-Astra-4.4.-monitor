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

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "DvbRepository"

-- ===========================================================================
-- Инициализация репозитория
-- ===========================================================================

--- @class DvbRepository : BaseRepository
local DvbRepository = BaseRepository.new(COMPONENT_NAME)

return DvbRepository
