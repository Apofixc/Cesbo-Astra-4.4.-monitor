-- 1. Стандартные Lua функции
local ipairs = ipairs
local pairs = pairs
local string_format = string.format
local table_concat = table.concat
local table_insert = table.insert
local tostring = tostring
local type = type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local DvbTuner = ModuleManager.get_module("dvb_tuner")
local DvbStorage = ModuleManager.get_module("dvb_storage")
local Utils = ModuleManager.get_module("utils")

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
--- @return boolean Статус выполнения
local function dvb_tuner_monitor(conf)
    if not conf or not conf.name_adapter then
        Logger.error(COMPONENT_NAME, "dvb_tuner_monitor: name_adapter is required")
        return false
    end

    if DvbStorage.find(conf.name_adapter) then
        Logger.error(COMPONENT_NAME, "dvb_tuner_monitor: tuner '%s' already exists", conf.name_adapter)
        return false
    end

    local tuner = DvbTuner.new(conf)
    if not tuner then
        return false
    end

    local instance = tuner:start()
    if instance then
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
--- @return any|nil Экземпляр тюнера (instance) или nil
local function find_dvb_conf(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner.instance
    end
    return nil
end

--- Обновляет параметры мониторинга DVB-тюнера.
--- @param name_adapter string Уникальное имя адаптера
--- @param params table Новые параметры (rate, time_check, method_comparison)
--- @return boolean Статус выполнения
local function update_dvb_monitor_parameters(name_adapter, params)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:update_parameters(params)
    end
    Logger.error(COMPONENT_NAME, "update_dvb_monitor_parameters: tuner '%s' not found", name_adapter)
    return false
end

--- Возвращает список всех активных мониторов тюнеров.
--- @return table<string, DvbTuner> Список мониторов
local function get_all_dvb_monitors()
    return DvbStorage.get_all()
end

--- Останавливает мониторинг DVB-тюнера и удаляет его из глобальной области видимости и хранилища.
--- @param name_adapter string Уникальное имя адаптера
--- @param force boolean|nil Принудительная остановка
--- @return boolean Статус выполнения
local function stop_dvb_monitor(name_adapter, force)
    if DvbStorage.unregister(name_adapter, force) then
        _G[name_adapter] = nil
        return true
    end
    Logger.error(COMPONENT_NAME, "stop_dvb_monitor: tuner '%s' not found", name_adapter)
    return false
end

--- Вспомогательная функция для управления зависимыми каналами.
--- Находит все каналы, использующие данный адаптер, и выполняет действие (остановка или запуск).
--- @param name_adapter string Имя адаптера
--- @param action string Действие: "stop" или "start"
--- @param [configs] table Список конфигураций для запуска (используется при action == "start")
--- @return table|nil Список сохраненных конфигураций при остановке
local function manage_dependent_channels(name_adapter, action, configs)
    local Channel = ModuleManager.get_module("channel")
    local ChannelStorage = ModuleManager.get_module("channel_storage")
    if not Channel or not ChannelStorage then return nil end

    if action == "stop" then
        local saved_configs = {}
        local dependent_channels = ChannelStorage.find_by_adapter(name_adapter)
        for name, _ in pairs(dependent_channels) do
            local ch_config = Channel.kill_stream(name)
            if ch_config then
                table_insert(saved_configs, ch_config)
            end
        end
        return saved_configs
    elseif action == "start" and configs then
        for _, conf in ipairs(configs) do
            Channel.make_stream(conf)
        end
    end
    return nil
end

--- Перезапускает мониторинг DVB-тюнера и обновляет глобальную ссылку.
--- @param name_adapter string Уникальное имя адаптера
--- @param new_params table|nil Новые параметры тюнинга
--- @param force boolean|nil Принудительный перезапуск
--- @return boolean Статус выполнения
local function restart_dvb_monitor(name_adapter, new_params, force)
    local tuner = DvbStorage.find(name_adapter)
    if not tuner then
        Logger.error(COMPONENT_NAME, "restart_dvb_monitor: tuner '%s' not found", name_adapter)
        return false
    end

    -- 1. Подготовка конфигурации
    local old_conf = Utils.table_copy(tuner.config)
    local new_conf = Utils.table_copy(old_conf)
    if new_params and type(new_params) == "table" then
        for k, v in pairs(new_params) do new_conf[k] = v end
    end

    -- 2. Управление каналами и счетчиками
    local old_channels_count = 0
    local saved_channels = {}

    if force then
        if tuner.instance and tuner.instance.__options then
            old_channels_count = tuner.instance.__options.channels or 0
        end
    else
        saved_channels = manage_dependent_channels(name_adapter, "stop") or {}
    end

    -- 3. Перезапуск монитора
    local function perform_restart(conf)
        if not stop_dvb_monitor(name_adapter, force) then return false end
        if not Adapter.dvb_tuner_monitor(conf) then return false end
        
        if force then
            local new_tuner = DvbStorage.find(name_adapter)
            if new_tuner and new_tuner.instance and new_tuner.instance.__options then
                new_tuner.instance.__options.channels = old_channels_count
            end
        end
        return true
    end

    if not perform_restart(new_conf) then
        Logger.error(COMPONENT_NAME, "restart_dvb_monitor: failed to restart '%s'. Rolling back...", name_adapter)
        perform_restart(old_conf)
        manage_dependent_channels(name_adapter, "start", saved_channels)
        return false
    end

    if not force then
        manage_dependent_channels(name_adapter, "start", saved_channels)
    end

    return true
end

--- Приостанавливает мониторинг тюнера
--- @param name_adapter string Имя адаптера
--- @return boolean Статус выполнения
local function pause_dvb_monitor(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:pause()
    end
    Logger.error(COMPONENT_NAME, "pause_dvb_monitor: tuner '%s' not found", tostring(name_adapter))
    return false
end

--- Возобновляет мониторинг тюнера
--- @param name_adapter string Имя адаптера
--- @return boolean Статус выполнения
local function resume_dvb_monitor(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:resume()
    end
    Logger.error(COMPONENT_NAME, "resume_dvb_monitor: tuner '%s' not found", tostring(name_adapter))
    return false
end

--- Сценарий "Переключение транспондера":
--- 1. Останавливает каналы
--- 2. Перенастраивает тюнер
--- 3. Запускает новые каналы, наследуя выходы старых
--- @param name_adapter string Имя адаптера
--- @param new_tuner_params table Новые параметры тюнера
--- @param reserve_input table|nil Список новых входов {name, input}
--- @return table|nil Снимок предыдущего состояния для возврата
local function switch_transponder(name_adapter, new_tuner_params, reserve_input)
    local tuner = DvbStorage.find(name_adapter)
    if not tuner then return nil end

    local old_tuner_params = Utils.table_copy(tuner.config)
    local saved_channels = manage_dependent_channels(name_adapter, "stop") or {}
    local old_channels_map = {}
    for _, conf in ipairs(saved_channels) do old_channels_map[conf.name] = conf end

    -- Перенастройка тюнера (force=false, каналы уже остановлены)
    if not restart_dvb_monitor(name_adapter, new_tuner_params, false) then
        manage_dependent_channels(name_adapter, "start", saved_channels)
        return nil
    end

    -- Запуск новых каналов с сохранением выходов
    if reserve_input and type(reserve_input) == "table" then
        local Channel = ModuleManager.get_module("channel")
        for _, item in ipairs(reserve_input) do
            local old_conf = old_channels_map[item.name]
            if old_conf and item.input then
                local final_conf = Utils.table_copy(old_conf)
                final_conf.input = item.input
                Channel.make_stream(final_conf)
            end
        end
    end

    Logger.info(COMPONENT_NAME, "Transponder switched on adapter '%s'", name_adapter)
    return { tuner_params = old_tuner_params, channels_configs = saved_channels }
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
Adapter.switch_transponder = switch_transponder

return Adapter
