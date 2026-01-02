-- 1. Стандартные Lua функции
local string_format = string.format
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
--- @return boolean success Статус выполнения
local function dvb_tuner_monitor(conf)
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
--- @return boolean success Статус выполнения
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

--- Останавливает мониторинг DVB-тюнера и удаляет его из глобальной области видимости.
--- @param name_adapter string Уникальное имя адаптера
--- @return boolean success Статус выполнения
local function stop_dvb_monitor(name_adapter)
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
local function restart_dvb_monitor(name_adapter)
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
local function pause_dvb_monitor(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:pause()
    end
    return false
end

--- Возобновляет мониторинг тюнера
--- @param name_adapter string Имя адаптера
--- @return boolean success
local function resume_dvb_monitor(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        return tuner:resume()
    end
    return false
end

--- Принудительно перезапускает тюнер (Emergency Reset)
--- @param name_adapter string Имя адаптера
--- @return boolean success
local function force_restart_dvb_tuner(name_adapter)
    local tuner = DvbStorage.find(name_adapter)
    if tuner then
        local success = tuner:force_restart()
        if success then
            _G[name_adapter] = tuner.instance
        end
        return success
    end
    return false
end

--- Сценарий "Переключение транспондера":
--- 1. Находит все каналы на адаптере
--- 2. Останавливает их и сохраняет конфигурацию (включая выходы)
--- 3. Перенастраивает тюнер
--- 4. Запускает новые каналы из reserve_input, наследуя выходы
--- @param name_adapter string Имя адаптера
--- @param new_tuner_params table Новые параметры тюнера
--- @param reserve_input table|nil Список новых входов {name, pnr, input}
--- @return table|nil old_state Снимок предыдущего состояния для возврата
local function switch_transponder(name_adapter, new_tuner_params, reserve_input)
    local tuner = DvbStorage.find(name_adapter)
    if not tuner then
        Logger.error(COMPONENT_NAME, "switch_transponder: tuner '%s' not found", name_adapter)
        return nil
    end

    local Channel = ModuleManager.get_module("channel")
    local ChannelStorage = ModuleManager.get_module("channel_storage")

    if not Channel or not ChannelStorage then
        Logger.error(COMPONENT_NAME, "switch_transponder: required modules (channel or channel_storage) not loaded")
        return nil
    end

    -- 1. Находим все каналы на этом адаптере
    local dependent_channels = ChannelStorage.find_by_adapter(name_adapter)
    local old_channels_configs = {}
    local old_channels_map = {}
    local old_tuner_params = Utils.table_copy(tuner.config)

    -- 2. Останавливаем каналы и сохраняем их полные конфиги
    for name, _ in pairs(dependent_channels) do
        local ch_config = Channel.kill_stream(name)
        if ch_config then
            table.insert(old_channels_configs, ch_config)
            old_channels_map[name] = ch_config
        end
    end

    -- 3. Перенастраиваем тюнер
    if not tuner:update_parameters(new_tuner_params) then
        Logger.error(COMPONENT_NAME, "switch_transponder: failed to retune tuner '%s'", name_adapter)
        -- Восстановление старых каналов
        for _, conf in ipairs(old_channels_configs) do Channel.make_stream(conf) end
        return nil
    end

    -- 4. Запускаем новые каналы из reserve_input
    if reserve_input and type(reserve_input) == "table" then
        for _, item in ipairs(reserve_input) do
            local name = item.name
            if name then
                local final_conf = {}
                local old_conf = old_channels_map[name]
                
                if old_conf then
                    -- Наследуем всё из старого конфига (выходы, мониторинг и т.д.)
                    final_conf = Utils.table_copy(old_conf)
                else
                    final_conf.name = name
                end

                -- Определяем новый вход
                if item.input then
                    -- Если передан готовый вход (URL или таблица)
                    final_conf.input = type(item.input) == "table" and item.input or { item.input }
                elseif item.pnr then
                    -- Если передан PNR, формируем DVB вход для текущего адаптера
                    final_conf.input = {
                        {
                            config = {
                                format = "dvb",
                                addr = name_adapter,
                                pnr = item.pnr
                            }
                        }
                    }
                end

                Channel.make_stream(final_conf)
            end
        end
    end

    Logger.info(COMPONENT_NAME, "Transponder switched successfully on adapter '%s'", name_adapter)
    
    return true, {
        tuner_params = old_tuner_params,
        channels_configs = old_channels_configs
    }
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
Adapter.force_restart_dvb_tuner = force_restart_dvb_tuner
Adapter.switch_transponder = switch_transponder

return Adapter
