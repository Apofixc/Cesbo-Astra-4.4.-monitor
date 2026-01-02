-- 1. Стандартные Lua функции
local string_format = string.format
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local DvbTuner = ModuleManager.get_module("dvb_tuner")
local DvbStorage = ModuleManager.get_module("dvb_storage")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Adapter"

-- 5. Инициализация объектов из загруженных модулей
--- @class Adapter
local Adapter = {}

--- Инициализирует и запускает мониторинг DVB-тюнера.
--- Автоматически регистрирует экземпляр тюнера в глобальной области видимости (_G)
--- под именем, указанным в conf.name_adapter.
--- @param conf table Конфигурация тюнера
--- @return boolean success Статус выполнения
function dvb_tuner_monitor(conf)
    if not conf or not conf.name_adapter then
        Logger.error(COMPONENT_NAME, "dvb_tuner_monitor: name_adapter is required")
        return false
    end

    if DvbStorage.find(conf.name_adapter) then
        Logger.error(COMPONENT_NAME, "dvb_tuner_monitor: tuner '%s' already exists", conf.name_adapter)
        return false
    end

    local success_new, tuner = DvbTuner.new(conf)
    if not success_new then
        return false
    end

    local success_start, instance = tuner:start()
    if success_start then
        DvbStorage.register(conf.name_adapter, tuner)
        _G[conf.name_adapter] = instance
        return true
    else
        Logger.error(COMPONENT_NAME, string_format("dvb_tuner_monitor: failed to start tuner '%s'", conf.name_adapter))
        return false
    end
end

--- Находит экземпляр DVB-тюнера по имени адаптера.
--- @param name_adapter string Уникальное имя адаптера
--- @return any|nil result Экземпляр тюнера (instance) или nil
function find_dvb_conf(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner.instance
    end
    return nil
end

--- Обновляет параметры мониторинга DVB-тюнера.
--- @param name_adapter string Уникальное имя адаптера
--- @param params table Новые параметры (rate, time_check, method_comparison)
--- @return boolean success Статус выполнения
--- @return string|nil error_message Сообщение об ошибке
function update_dvb_monitor_parameters(name_adapter, params)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        local success = tuner:update_parameters(params)
        return success, (not success and "Failed to update parameters" or nil)
    end
    local err = string_format("update_dvb_monitor_parameters: tuner '%s' not found", name_adapter)
    Logger.error(COMPONENT_NAME, err)
    return false, err
end

--- Возвращает список всех активных мониторов тюнеров.
--- @return table<string, DvbTuner> Список мониторов
function get_all_dvb_monitors()
    return DvbStorage.get_all()
end

--- Останавливает мониторинг DVB-тюнера и удаляет его из глобальной области видимости.
--- @param name_adapter string Уникальное имя адаптера
--- @return boolean success Статус выполнения
function stop_dvb_monitor(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        local success = tuner:stop()
        if success then
            _G[name_adapter] = nil
        end
        return success
    end
    Logger.error(COMPONENT_NAME, "stop_dvb_monitor: tuner '%s' not found", name_adapter)
    return false
end

--- Перезапускает мониторинг DVB-тюнера и обновляет глобальную ссылку.
--- @param name_adapter string Уникальное имя адаптера
--- @return boolean success Статус выполнения
function restart_dvb_monitor(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        local success, instance = tuner:restart()
        if success then
            _G[name_adapter] = instance
        end
        return success
    end
    Logger.error(COMPONENT_NAME, "restart_dvb_monitor: tuner '%s' not found", name_adapter)
    return false
end

--- Приостанавливает мониторинг тюнера
--- @param name_adapter string Имя адаптера
--- @return boolean success
function pause_dvb_monitor(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:pause()
    end
    return false
end

--- Возобновляет мониторинг тюнера
--- @param name_adapter string Имя адаптера
--- @return boolean success
function resume_dvb_monitor(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:resume()
    end
    return false
end

-- Экспорт в таблицу модуля для ModuleManager
Adapter.dvb_tuner_monitor = dvb_tuner_monitor
Adapter.find_dvb_conf = find_dvb_conf
Adapter.update_dvb_monitor_parameters = update_dvb_monitor_parameters
Adapter.get_all_dvb_monitors = get_all_dvb_monitors
Adapter.stop_dvb_monitor = stop_dvb_monitor
Adapter.restart_dvb_monitor = restart_dvb_monitor
Adapter.pause_dvb_monitor = pause_dvb_monitor
Adapter.resume_dvb_monitor = resume_dvb_monitor

return Adapter
