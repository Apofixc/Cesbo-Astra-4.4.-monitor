-- ===========================================================================
-- Модуль `adapters.adapter`
--
-- Высокоуровневый интерфейс для управления DVB-адаптерами и их мониторингом.
-- Обеспечивает координацию между репозиторием тюнеров, мониторами и каналами.
-- ===========================================================================

-- 1. Стандартные Lua функции
local ipairs = _G.ipairs
local pairs = _G.pairs
local string_format = _G.string.format
local tostring = _G.tostring
local type = _G.type
local os_time = _G.os.time

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local TunerMonitor = ModuleManager.get_module("tuner_monitor")
local DvbRepository = ModuleManager.get_module("dvb_repository")
local Utils = ModuleManager.get_module("utils")
local Channel = ModuleManager.get_module("channel")
local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")

-- 3. Глобальные зависимости Astra
-- (Модуль не использует внешние зависимости Astra напрямую)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Adapter"

--- Минимальный интервал между перезапусками одного адаптера (сек)
local RESTART_DEBOUNCE_TIME = 5

-- 5. Внутреннее состояние (Private State)
--- @class AdapterState
--- @field last_restarts table<string, number> Время последнего рестарта адаптеров
local state = {
    last_restarts = {}
}

--- @class Adapter
local Adapter = {}

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Выполняет физический перезапуск монитора тюнера
--- @param name_adapter string Уникальное имя адаптера
--- @param conf table Конфигурация для запуска
--- @param force boolean|nil Принудительная остановка
--- @param old_channels_count number Предыдущее количество каналов (для force)
--- @param old_conf table Старая конфигурация для отката
--- @return boolean Статус выполнения
local function _perform_restart(name_adapter, conf, force, old_channels_count, old_conf)
    if not Adapter.stop_dvb_monitor(name_adapter, force) then
        return false
    end

    if not Adapter.dvb_tuner_monitor(conf) then
        return false
    end

    local new_tuner = DvbRepository:find(name_adapter)
    if new_tuner then
        -- Сохраняем бэкап в новый объект
        new_tuner:set_backup(old_conf, {})

        local instance = new_tuner:get_instance()
        if force and instance and instance.__options then
            instance.__options.channels = old_channels_count
        end
    end

    -- Обновляем время последнего успешного рестарта
    state.last_restarts[name_adapter] = os_time()

    return true
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Инициализирует и запускает мониторинг DVB-тюнера.
--- Автоматически регистрирует экземпляр тюнера в глобальной области видимости (_G)
--- под именем, указанным в conf.name_adapter.
--- @param conf table Конфигурация тюнера
--- @return boolean Статус выполнения
function Adapter.dvb_tuner_monitor(conf)
    if not conf or not conf.name_adapter then
        Logger.error(COMPONENT_NAME, "dvb_tuner_monitor: параметр name_adapter обязателен")
        return false
    end

    if DvbRepository:find(conf.name_adapter) then
        Logger.error(COMPONENT_NAME, "dvb_tuner_monitor: тюнер '%s' уже существует", conf.name_adapter)
        return false
    end

    local tuner = TunerMonitor.new(conf)
    if not tuner then
        return false
    end

    local instance = tuner:start()
    if instance then
        DvbRepository:register(conf.name_adapter, tuner, TunerMonitor)
        _G[conf.name_adapter] = instance
        return true
    else
        Logger.error(COMPONENT_NAME,
            string_format("dvb_tuner_monitor: не удалось запустить тюнер '%s'", conf.name_adapter))
        return false
    end
end

--- Находит объект DVB-тюнера по имени адаптера.
--- @param name_adapter string Уникальное имя адаптера
--- @return TunerMonitor|nil Объект тюнера или nil
function Adapter.find_dvb_monitor(name_adapter)
    return DvbRepository:find(name_adapter)
end

--- Обновляет параметры мониторинга DVB-тюнера.
--- @param name_adapter string Уникальное имя адаптера
--- @param params table Новые параметры (rate, time_check, method_comparison)
--- @return boolean Статус выполнения
function Adapter.update_dvb_monitor_parameters(name_adapter, params)
    local tuner = DvbRepository:find(name_adapter)
    if tuner then
        return tuner:update_parameters(params)
    end
    Logger.error(COMPONENT_NAME, "update_dvb_monitor_parameters: тюнер '%s' не найден", name_adapter)
    return false
end

--- Возвращает список всех активных мониторов тюнеров.
--- @return table<string, TunerMonitor> Список мониторов
function Adapter.get_all_dvb_monitors()
    return DvbRepository:get_all()
end

--- Останавливает мониторинг DVB-тюнера и удаляет его из глобальной области видимости и хранилища.
--- @param name_adapter string Уникальное имя адаптера
--- @param force boolean|nil Принудительная остановка
--- @return table|nil Оригинальная конфигурация тюнера при успехе, иначе nil
function Adapter.stop_dvb_monitor(name_adapter, force)
    local config = DvbRepository:unregister(name_adapter, force)
    if config then
        _G[name_adapter] = nil
        return config
    end
    Logger.error(COMPONENT_NAME, "stop_dvb_monitor: тюнер '%s' не найден или занят", name_adapter)
    return nil
end

--- Останавливает все каналы, использующие указанный адаптер.
--- @param name_adapter string Имя адаптера
--- @return table Список сохраненных конфигураций каналов
function Adapter.stop_dependent_channels(name_adapter)
    local ChannelRepository = ModuleManager.get_module("channel_repository")
    if not ChannelRepository then
        Logger.error(COMPONENT_NAME, "Модуль ChannelRepository не найден")
        return {}
    end
    return ChannelRepository:stop_dependent_channels(name_adapter)
end

--- Запускает каналы на основе предоставленных конфигураций.
--- @param configs table Список конфигураций каналов
function Adapter.start_dependent_channels(configs)
    local ChannelRepository = ModuleManager.get_module("channel_repository")
    if not ChannelRepository then
        Logger.error(COMPONENT_NAME, "Модуль ChannelRepository не найден")
        return
    end
    ChannelRepository:start_dependent_channels(configs)
end

--- Унифицированный метод переконфигурации группы адаптеров и зависимых каналов.
--- Обеспечивает атомарность: каналы перезапускаются один раз, даже если затронуто несколько их тюнеров.
--- @param adapter_list table Список имен адаптеров
--- @param options table Опции (adapter_params, channel_updates, force)
--- @return boolean success
function Adapter.reconfigure(adapter_list, options)
    if type(adapter_list) ~= "table" then return false end
    options = options or {}

    local ChannelRepository = ModuleManager.get_module("channel_repository")
    if not ChannelRepository or not Channel then
        Logger.error(COMPONENT_NAME, "reconfigure: модули Channel или ChannelRepository не найдены")
        return false
    end

    -- 1. Собираем все уникальные зависимые каналы
    local affected_channels = {}
    for _, adapter_name in ipairs(adapter_list) do
        local deps = ChannelRepository:find_by_adapter(adapter_name)
        for name, ch_data in pairs(deps) do
            if not affected_channels[name] then
                affected_channels[name] = Utils.table_copy(ch_data.config)
            end
        end
    end

    -- 2. Останавливаем все затронутые каналы
    for name, _ in pairs(affected_channels) do
        Channel.kill_stream(name)
    end

    -- 3. Перезапускаем адаптеры
    local success = true
    for _, adapter_name in ipairs(adapter_list) do
        local tuner = DvbRepository:find(adapter_name)
        if tuner then
            local old_conf = Utils.table_copy(tuner:get_config())
            local target_conf = Utils.table_copy(old_conf)
            local new_params = options.adapter_params and options.adapter_params[adapter_name]
            if new_params then
                for k, v in pairs(new_params) do target_conf[k] = v end
            end

            -- При реконфигурации мы всегда используем force для монитора,
            -- так как каналы мы уже остановили сами.
            if not _perform_restart(adapter_name, target_conf, true, 0, old_conf) then
                Logger.error(COMPONENT_NAME, "reconfigure: ошибка рестарта адаптера %s", adapter_name)
                success = false
            end
        end
    end

    -- 4. Применяем обновления входов для каналов
    if options.channel_updates then
        for name, new_input in pairs(options.channel_updates) do
            if affected_channels[name] then
                affected_channels[name].input = new_input
            end
        end
    end

    -- 5. Запускаем каналы обратно
    for _, conf in pairs(affected_channels) do
        Channel.make_stream(conf)
    end

    return success
end

--- Перезапускает мониторинг DVB-тюнера и обновляет глобальную ссылку.
--- @param name_adapter string Уникальное имя адаптера
--- @param new_params table|nil Новые параметры тюнинга
--- @param force boolean|nil Принудительный перезапуск
--- @return boolean Статус выполнения
function Adapter.restart_dvb_monitor(name_adapter, new_params, force)
    local tuner = DvbRepository:find(name_adapter)
    if not tuner then
        Logger.error(COMPONENT_NAME, "restart_dvb_monitor: тюнер '%s' не найден", name_adapter)
        return false
    end

    -- Защита от "дребезга" (Debounce)
    local now = os_time()
    local last_restart = state.last_restarts[name_adapter] or 0
    if not force and now - last_restart < RESTART_DEBOUNCE_TIME then
        Logger.warning(COMPONENT_NAME,
            "restart_dvb_monitor: пропуск рестарта '%s' (слишком часто, осталось %d сек)",
            name_adapter, RESTART_DEBOUNCE_TIME - (now - last_restart))
        return true
    end

    return Adapter.reconfigure({ name_adapter }, {
        adapter_params = { [name_adapter] = new_params },
        force = force
    })
end
--- @param name_adapter string Имя адаптера
--- @return boolean Статус выполнения
function Adapter.pause_dvb_monitor(name_adapter)
    local tuner = DvbRepository:find(name_adapter)
    if tuner then
        return tuner:pause()
    end
    Logger.error(COMPONENT_NAME, "pause_dvb_monitor: тюнер '%s' не найден", tostring(name_adapter))
    return false
end

--- Возобновляет мониторинг тюнера
--- @param name_adapter string Имя адаптера
--- @return boolean Статус выполнения
function Adapter.resume_dvb_monitor(name_adapter)
    local tuner = DvbRepository:find(name_adapter)
    if tuner then
        return tuner:resume()
    end
    Logger.error(COMPONENT_NAME, "resume_dvb_monitor: тюнер '%s' не найден", tostring(name_adapter))
    return false
end

--- Запускает обновление PSI таблиц для адаптера
--- @param name_adapter string Имя адаптера
--- @return boolean Статус запуска
function Adapter.update_dvb_psi(name_adapter)
    local tuner = DvbRepository:find(name_adapter)
    if tuner then
        return tuner:psi_update()
    end
    Logger.error(COMPONENT_NAME, "update_dvb_psi: тюнер '%s' не найден", tostring(name_adapter))
    return false
end

--- Возвращает собранные PSI данные адаптера
--- @param name_adapter string Имя адаптера
--- @return table|nil Таблица PSI или nil
function Adapter.get_dvb_psi(name_adapter)
    local tuner = DvbRepository:find(name_adapter)
    if tuner then
        return tuner:get_psi()
    end
    Logger.error(COMPONENT_NAME, "get_dvb_psi: тюнер '%s' не найден", tostring(name_adapter))
    return nil
end

--- Сценарий "Переключение транспондера":
--- 1. Останавливает каналы
--- 2. Перенастраивает тюнер
--- 3. Запускает новые каналы с обновленными входами
--- @param name_adapter string Имя адаптера
--- @param new_tuner_params table Новые параметры тюнера
--- @param reserve_input table|nil Список новых входов {name, input}
--- @return table|nil Снимок предыдущего состояния для возврата
function Adapter.switch_transponder(name_adapter, new_tuner_params, reserve_input)
    local tuner = DvbRepository:find(name_adapter)
    if not tuner then return nil end

    local old_tuner_params = Utils.table_copy(tuner:get_config())
    local channel_updates = {}
    if reserve_input and type(reserve_input) == "table" then
        for _, item in ipairs(reserve_input) do
            if item.name and item.input then
                channel_updates[item.name] = item.input
            end
        end
    end

    local success = Adapter.reconfigure({ name_adapter }, {
        adapter_params = { [name_adapter] = new_tuner_params },
        channel_updates = channel_updates,
        force = true
    })

    if success then
        Logger.info(COMPONENT_NAME, "Транспондер успешно переключен на адаптере '%s'", name_adapter)
        return { tuner_params = old_tuner_params }
    end

    return nil
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================

return Adapter
