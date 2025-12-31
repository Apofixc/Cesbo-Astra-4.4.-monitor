-- ===========================================================================
-- Модуль `adapters.adapter`
--
-- Предоставляет интерфейс для управления DVB-тюнерами и их мониторингом.
-- Использует `DvbMonitorDispatcher` для создания, регистрации, поиска и обновления
-- параметров DVB-мониторов.
--
-- Основные функции:
-- - `get_all_dvb_monitors()`: Получает список всех активных DVB-мониторов.
-- - `dvb_tuner_monitor(conf)`: Инициализирует и запускает мониторинг DVB-тюнера.
-- - `find_dvb_conf(name_adapter)`: Находит конфигурацию DVB-тюнера по имени адаптера.
-- - `update_dvb_monitor_parameters(name_adapter, params)`: Обновляет параметры мониторинга DVB-тюнера.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local log_info = Logger.info
local log_error = Logger.error
local DvbTunerMonitor = ModuleManager.get_module("dvb_tuner")
local DvbMonitorDispatcher = ModuleManager.get_module("dvb_monitor_dispatcher")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых глобальных зависимостей Astra в этом модуле

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Adapter"

-- 5. Инициализация объектов из загруженных модулей
--- @type DvbMonitorDispatcher
local dvb_monitor_manager = DvbMonitorDispatcher:new()

--- Возвращает список всех активных DVB-мониторов.
--- Эта функция запрашивает у `DvbMonitorManager` список всех зарегистрированных
--- и активных DVB-мониторов.
--- @return table result Таблица со всеми объектами DVB-мониторов.
function get_all_dvb_monitors()
    log_info(COMPONENT_NAME, "Получение всех DVB-мониторов.")
    return dvb_monitor_manager:get_all_monitors()
end

--- Инициализирует и запускает мониторинг DVB-тюнера.
--- Создает новый DVB-монитор на основе предоставленной конфигурации и регистрирует его
--- в `DvbMonitorManager`.
--- @param conf table Таблица конфигурации для DVB-тюнера. Ожидается поле `name_adapter` (string).
--- @return boolean success Статус выполнения
--- @return any|nil result Экземпляр DVB-тюнера или nil
function dvb_tuner_monitor(conf)
    if not conf or type(conf) ~= 'table' then
        log_error(COMPONENT_NAME, "Предоставлена неверная конфигурация. Ожидалась таблица, получено: %s.", type(conf))
        return false, nil
    end
    if not conf.name_adapter or type(conf.name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "В конфигурации отсутствует 'name_adapter' или это не строка.")
        return false, nil
    end

    log_info(COMPONENT_NAME, "Попытка создать и зарегистрировать DVB-монитор '%s'.", conf.name_adapter)
    return dvb_monitor_manager:create_and_register_dvb_monitor(conf)
end

--- Находит конфигурацию DVB-тюнера по имени адаптера.
--- Ищет зарегистрированный DVB-монитор по его имени адаптера.
--- @param name_adapter string Имя адаптера, по которому осуществляется поиск.
--- @return boolean success Статус выполнения
--- @return any|nil result Экземпляр DVB-тюнера или nil
function find_dvb_conf(name_adapter)
    if not name_adapter or type(name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "Неверный 'name_adapter': ожидалась строка, получено: %s.", type(name_adapter))
        return false, nil
    end
    local success_get, monitor = dvb_monitor_manager:get_monitor(name_adapter)
    if success_get and monitor then
        return true, monitor.instance
    end
    log_info(COMPONENT_NAME, "Конфигурация DVB для адаптера '%s' не найдена.", name_adapter)
    return false, nil
end

--- Обновляет параметры мониторинга DVB-тюнера.
--- Обновляет параметры существующего DVB-монитора, идентифицируемого по имени адаптера.
--- @param name_adapter string Имя адаптера, параметры которого нужно обновить.
--- @param params table Таблица с новыми параметрами для DVB-монитора.
--- @return boolean success Статус выполнения
--- @return nil result
function update_dvb_monitor_parameters(name_adapter, params)
    if not name_adapter or type(name_adapter) ~= 'string' then
        log_error(COMPONENT_NAME, "Неверный 'name_adapter': ожидалась строка, получено: %s.", type(name_adapter))
        return false, nil
    end
    if not params or type(params) ~= 'table' then
        log_error(COMPONENT_NAME, "Неверные параметры для '%s': ожидалась таблица, получено: %s.", name_adapter, type(params))
        return false, nil
    end

    log_info(COMPONENT_NAME, "Попытка обновить параметры для DVB-монитора '%s'.", name_adapter)
    local success, err = dvb_monitor_manager:update_monitor_parameters(name_adapter, params)
    if success then
        log_info(COMPONENT_NAME, "Параметры успешно обновлены для DVB-монитора: %s.", name_adapter)
    else
        log_error(COMPONENT_NAME, "Не удалось обновить параметры для DVB-монитора: %s.", name_adapter)
    end
    return success, nil
end
