-- 1. Стандартные Lua функции
local ipairs = ipairs
local pairs = pairs
local string_format = string.format
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

--- Находит объект DVB-тюнера по имени адаптера.
--- @param name_adapter string Уникальное имя адаптера
--- @return DvbTuner|nil Объект тюнера или nil
local function find_dvb_monitor(name_adapter)
    return DvbStorage.find(name_adapter)
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
--- @return table|nil Оригинальная конфигурация тюнера при успехе, иначе nil
local function stop_dvb_monitor(name_adapter, force)
    local config = DvbStorage.unregister(name_adapter, force)
    if config then
        _G[name_adapter] = nil
        return config
    end
    Logger.error(COMPONENT_NAME, "stop_dvb_monitor: tuner '%s' not found or busy", name_adapter)
    return nil
end

--- Останавливает все каналы, использующие указанный адаптер.
--- @param name_adapter string Имя адаптера
--- @return table Список сохраненных конфигураций каналов
local function stop_dependent_channels(name_adapter)
    local Channel = ModuleManager.get_module("channel")
    local ChannelStorage = ModuleManager.get_module("channel_storage")
    local saved_configs = {}
    if not Channel or not ChannelStorage then
        return saved_configs
    end

    local dependent_channels = ChannelStorage.find_by_adapter(name_adapter)
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
local function start_dependent_channels(configs)
    if not configs or type(configs) ~= "table" then
        return
    end
    local Channel = ModuleManager.get_module("channel")
    if not Channel then
        return
    end

    for _, conf in ipairs(configs) do
        Channel.make_stream(conf)
    end
end

--- Перезапускает мониторинг DVB-тюнера и обновляет глобальную ссылку.
--- @param name_adapter string Уникальное имя адаптера
--- @param new_params table|nil Новые параметры тюнинга
--- @param force boolean|nil Принудительный перезапуск
--- @param _pre_saved_channels table|nil Предварительно сохраненные конфигурации каналов
--- @return boolean Статус выполнения
local function restart_dvb_monitor(name_adapter, new_params, force, _pre_saved_channels)
    local tuner = DvbStorage.find(name_adapter)
    if not tuner then
        Logger.error(COMPONENT_NAME, "restart_dvb_monitor: tuner '%s' not found", name_adapter)
        return false
    end

    -- 1. Подготовка конфигурации
    local old_conf = Utils.table_copy(tuner:get_config())
    local new_conf = Utils.table_copy(old_conf)
    if new_params and type(new_params) == "table" then
        for k, v in pairs(new_params) do new_conf[k] = v end
    end

    -- 2. Управление каналами и счетчиками
    local old_channels_count = 0
    local saved_channels = {}

    if force then
        local instance = tuner:get_instance()
        if instance and instance.__options then
            old_channels_count = instance.__options.channels or 0
        end
    else
        saved_channels = _pre_saved_channels or stop_dependent_channels(name_adapter)
    end

    -- 3. Перезапуск монитора
    local function perform_restart(conf)
        if not stop_dvb_monitor(name_adapter, force) then return false end
        if not Adapter.dvb_tuner_monitor(conf) then return false end
        
        local new_tuner = DvbStorage.find(name_adapter)
        if new_tuner then
            -- Сохраняем бэкап в новый объект
            new_tuner:set_backup(old_conf, saved_channels)
            
            local instance = new_tuner:get_instance()
            if force and instance and instance.__options then
                instance.__options.channels = old_channels_count
            end
        end
        return true
    end

    if not perform_restart(new_conf) then
        Logger.error(COMPONENT_NAME, "restart_dvb_monitor: failed to restart '%s'. Rolling back...", name_adapter)
        perform_restart(old_conf)
        start_dependent_channels(saved_channels)
        return false
    end

    if not force then
        start_dependent_channels(saved_channels)
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

--- Запускает обновление PSI таблиц для адаптера
--- @param name_adapter string Имя адаптера
--- @return boolean Статус запуска
local function update_dvb_psi(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:psi_update()
    end
    Logger.error(COMPONENT_NAME, "update_dvb_psi: tuner '%s' not found", tostring(name_adapter))
    return false
end

--- Возвращает собранные PSI данные адаптера
--- @param name_adapter string Имя адаптера
--- @return table|nil Таблица PSI или nil
local function get_dvb_psi(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:get_psi()
    end
    Logger.error(COMPONENT_NAME, "get_dvb_psi: tuner '%s' not found", tostring(name_adapter))
    return nil
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

    local old_tuner_params = Utils.table_copy(tuner:get_config())
    local saved_channels = stop_dependent_channels(name_adapter)
    
    -- Создаем карту новых входов для быстрой проверки
    local reserve_map = {}
    if reserve_input and type(reserve_input) == "table" then
        for _, item in ipairs(reserve_input) do
            if item.name then reserve_map[item.name] = item.input end
        end
    end

    -- Фильтруем сохраненные каналы: исключаем те, которые будут запущены с новыми входами
    local filtered_saved_channels = {}
    local old_channels_map = {}
    for _, conf in ipairs(saved_channels) do
        old_channels_map[conf.name] = conf
        if not reserve_map[conf.name] then
            table_insert(filtered_saved_channels, conf)
        end
    end

    -- Перенастройка тюнера (force=false, каналы уже остановлены)
    -- Передаем отфильтрованный список, чтобы restart_dvb_monitor не запустил лишнего
    if not restart_dvb_monitor(name_adapter, new_tuner_params, false, filtered_saved_channels) then
        -- В случае ошибки restart_dvb_monitor уже попытался запустить filtered_saved_channels.
        -- Нам нужно запустить остальные (те, что были в reserve_map), чтобы полностью восстановить состояние.
        local remaining_channels = {}
        for _, conf in ipairs(saved_channels) do
            if reserve_map[conf.name] then
                table_insert(remaining_channels, conf)
            end
        end
        start_dependent_channels(remaining_channels)
        return nil
    end

    -- После успешного рестарта в restart_dvb_monitor уже сохранен бэкап,
    -- но если мы переключаем транспондер с новыми входами, 
    -- возможно стоит обновить бэкап или оставить как есть (там старые конфиги).

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
Adapter.find_dvb_monitor = find_dvb_monitor
Adapter.update_dvb_monitor_parameters = update_dvb_monitor_parameters
Adapter.get_all_dvb_monitors = get_all_dvb_monitors
Adapter.stop_dvb_monitor = stop_dvb_monitor
Adapter.restart_dvb_monitor = restart_dvb_monitor
Adapter.pause_dvb_monitor = pause_dvb_monitor
Adapter.resume_dvb_monitor = resume_dvb_monitor
Adapter.update_dvb_psi = update_dvb_psi
Adapter.get_dvb_psi = get_dvb_psi
Adapter.switch_transponder = switch_transponder

return Adapter
