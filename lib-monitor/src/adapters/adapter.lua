-- 1. Стандартные Lua функции
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

--- Инициализирует и запускает мониторинг DVB-тюнера
--- @param conf table Конфигурация
--- @return boolean success
--- @return any instance или nil
function dvb_tuner_monitor(conf)
    if not conf or not conf.name_adapter then
        Logger.error(COMPONENT_NAME, "dvb_tuner_monitor: name_adapter is required")
        return false, nil
    end

    if DvbStorage.find(conf.name_adapter) then
        Logger.error(COMPONENT_NAME, "dvb_tuner_monitor: tuner '%s' already exists", conf.name_adapter)
        return false, nil
    end

    local success_new, tuner = DvbTuner.new(conf)
    if not success_new then
        return false, nil
    end

    if tuner:start() then
        DvbStorage.register(conf.name_adapter, tuner)
        return true, tuner.instance
    else
        Logger.error(COMPONENT_NAME, "dvb_tuner_monitor: failed to start tuner '%s'", conf.name_adapter)
        return false, nil
    end
end

--- Находит конфигурацию DVB-тюнера по имени адаптера
--- @param name_adapter string
--- @return boolean success
--- @return any instance или nil
function find_dvb_conf(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return true, tuner.instance
    end
    return false, nil
end

--- Обновляет параметры мониторинга DVB-тюнера
--- @param name_adapter string
--- @param params table
--- @return boolean success
function update_dvb_monitor_parameters(name_adapter, params)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:update_parameters(params)
    end
    Logger.error(COMPONENT_NAME, "update_dvb_monitor_parameters: tuner '%s' not found", name_adapter)
    return false
end

--- Возвращает список всех адаптеров
function get_all_dvb_monitors()
    return DvbStorage.get_all()
end

-- Экспорт в таблицу модуля для ModuleManager
Adapter.dvb_tuner_monitor = dvb_tuner_monitor
Adapter.find_dvb_conf = find_dvb_conf
Adapter.update_dvb_monitor_parameters = update_dvb_monitor_parameters
Adapter.get_all_dvb_monitors = get_all_dvb_monitors

return Adapter
