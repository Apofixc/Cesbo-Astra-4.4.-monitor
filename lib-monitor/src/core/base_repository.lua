-- ===========================================================================
-- Модуль `core.base_repository`
--
-- Базовый класс для репозиториев, управляющих жизненным циклом мониторов.
-- Обеспечивает регистрацию, поиск, атомарное восстановление и автономный мониторинг.
-- ===========================================================================

-- 1. Стандартные Lua функции
local collectgarbage = _G.collectgarbage
local ipairs = _G.ipairs
local os_time = _G.os.time
local pairs = _G.pairs
local setmetatable = _G.setmetatable
local tostring = _G.tostring
local type = _G.type

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local BaseMonitor = ModuleManager.get_module("core.base_monitor")
local MonitorConfig = ModuleManager.get_module("monitor_config")
local Scheduler = ModuleManager.get_module("core.scheduler")
local EventDispatcher = ModuleManager.get_module("core.event_dispatcher")

-- 3. Глобальные зависимости Astra
-- (Нет прямых зависимостей)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "BaseRepository"

-- 5. Внутреннее состояние (Private State)
-- (Для классов состояние инкапсулировано в экземпляре, создаваемом в .new)

--- Настройки по умолчанию
local DEFAULT_RECOVER_INTERVAL = (MonitorConfig and MonitorConfig.AutoRecoverInterval) or 300
local DEFAULT_MAX_ATTEMPTS = (MonitorConfig and MonitorConfig.MaxRecoveryAttempts) or 3
local DEFAULT_COOLDOWN_TIME = (MonitorConfig and MonitorConfig.RecoveryCooldown) or 3600 -- 1 час стабильной работы для сброса попыток
local DEFAULT_WATCHDOG_INTERVAL = 5

--- Типы событий репозитория
local EVENTS = {
    RECOVERY_ATTEMPT = "repo:recovery_attempt",
    RECOVERY_SUCCESS = "repo:recovery_success",
    RECOVERY_FAILED = "repo:recovery_failed",
    RECOVERY_LIMIT = "repo:recovery_limit_reached"
}

--- @class BaseRepository
--- @field protected _state table Внутреннее состояние репозитория
--- @field protected _component_name string Имя компонента для логирования
--- @field protected _maintenance_task_id string|nil ID задачи обслуживания в планировщике
local BaseRepository = {}
BaseRepository.__index = BaseRepository

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Выполняет очистку ресурсов монитора при удалении
--- @param name string Имя монитора
--- @param instance any Экземпляр монитора
--- @param force boolean Флаг принудительной остановки
--- @return table|nil Конфигурация монитора
function BaseRepository:_destroy_instance(name, instance, force)
    -- Все мониторы наследуются от BaseMonitor и имеют метод destroy
    local config = instance.destroy and instance:destroy(force)
    if config then
        local s = self._state
        s.monitors[name] = nil
        s.classes[name] = nil
        s.recovery.attempts[name] = nil
        s.recovery.last_success[name] = nil
        s.stats.active = s.stats.active - 1
        
        -- Вызов хука для очистки специфичных данных в наследниках
        self:_on_instance_destroyed(name)

        Logger.debug(self._component_name,
            "Объект '%s' удален и остановлен (принудительно: %s).",
            name, tostring(force))
        return config
    end
    return nil
end

--- Публикует событие через EventDispatcher
--- @param event_type string Тип события
--- @param name string Имя монитора
--- @param data? table Дополнительные данные
function BaseRepository:_emit_event(event_type, name, data)
    local dispatcher = EventDispatcher and EventDispatcher.get_instance()
    if not dispatcher then 
        print("[DEBUG] No dispatcher found in _emit_event")
        return 
    end

    local event_data = {
        repo = self._component_name,
        monitor = name,
        timestamp = os_time()
    }
    if data then
        for k, v in pairs(data) do event_data[k] = v end
    end

    dispatcher:emit_safe(event_type, event_data, EventDispatcher.PRIORITIES.HIGH)
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Создает новый экземпляр базового репозитория
--- @param component_name string Имя компонента для логирования
--- @return BaseRepository Экземпляр репозитория
function BaseRepository.new(component_name)
    local self = setmetatable({}, BaseRepository)

    -- Организация внутреннего состояния (Private State)
    self._state = {
        -- Хранилище объектов
        monitors = {},           -- Активные экземпляры мониторов: name -> instance
        classes = {},            -- Классы (мета-таблицы) для пересоздания: name -> class

        -- Настройки (копируются из MonitorConfig для поддержки API)
        settings = {
            auto_recover = {
                enabled = (MonitorConfig and MonitorConfig.AutoRecoverEnabled) or false,
                interval = (MonitorConfig and MonitorConfig.AutoRecoverInterval) or DEFAULT_RECOVER_INTERVAL,
                max_attempts = (MonitorConfig and MonitorConfig.MaxRecoveryAttempts) or DEFAULT_MAX_ATTEMPTS,
                cooldown = (MonitorConfig and MonitorConfig.RecoveryCooldown) or DEFAULT_COOLDOWN_TIME
            },
            watchdog = {
                enabled = (MonitorConfig and MonitorConfig.WatchdogEnabled) or false,
                max_attempts = (MonitorConfig and MonitorConfig.WatchdogMaxRetries) or 3,
                interval = (MonitorConfig and MonitorConfig.WatchdogInterval) or DEFAULT_WATCHDOG_INTERVAL
            }
        },

        -- Состояние восстановления
        recovery = {
            attempts = {},       -- История попыток восстановления: name -> count
            last_success = {},   -- Время последнего успешного восстановления: name -> timestamp
            last_check = 0
        },

        -- Статистика
        stats = {
            active = 0,          -- Текущее количество активных объектов
            total_recovered = 0, -- Всего успешно восстановлено
            total_failed = 0,    -- Всего неудачных попыток
            limit_reached = 0    -- Количество мониторов, достигших лимита
        }
    }

    self._component_name = component_name or COMPONENT_NAME
    self._maintenance_task_id = nil

    -- Инициализация единого цикла обслуживания
    self:_start_maintenance_task()

    return self
end

--- Запускает единую задачу обслуживания в планировщике
--- @private
function BaseRepository:_start_maintenance_task()
    local scheduler = Scheduler and Scheduler.get_instance()
    if not scheduler then return end

    local task_id = "maintenance_" .. self._component_name
    local interval = self._state.settings.watchdog.interval

    -- Используем immediate = true для мгновенного запуска первого тика
    scheduler:add_task(task_id, function()
        self:_maintenance_tick()
    end, interval, { immediate = true })

    self._maintenance_task_id = task_id
end

--- Хук, вызываемый перед пересозданием экземпляра монитора.
--- Переопределяется в наследниках для выполнения инфраструктурных действий (restart stream/adapter).
--- @protected
--- @param name string Имя монитора
--- @param reason string Причина восстановления ("silence" или "watchdog")
--- @return boolean Если false, восстановление будет прервано
function BaseRepository:_on_before_recreate(name, reason)
    return true
end

--- Хук, вызываемый после удаления экземпляра монитора.
--- @protected
--- @param name string Имя монитора
function BaseRepository:_on_instance_destroyed(name)
    -- Базовая реализация пустая
end

--- Единый цикл обслуживания: проверка тишины и здоровья мониторов
--- @private
--- @return number Количество восстановленных
--- @return number Количество неудачных попыток
function BaseRepository:_maintenance_tick()
    local now = os_time()
    local s = self._state
    local settings = s.settings
    local recovered = 0
    local failed = 0
    
    s.recovery.last_check = now

    -- Создаем список имен для безопасной итерации (т.к. внутри можем удалять/добавлять)
    local names = {}
    for name in pairs(s.monitors) do
        names[#names + 1] = name
    end

    for _, name in ipairs(names) do
        local monitor = s.monitors[name]
        local class = s.classes[name]
        if not monitor or not class then goto next_monitor end

        local health = monitor.get_software_status and monitor:get_software_status()
        if not health then goto next_monitor end

        -- 1. Механизм Cooldown: сброс попыток при стабильной работе
        local last_success = s.recovery.last_success[name] or 0
        if last_success > 0 and now - last_success > settings.auto_recover.cooldown then
            if (s.recovery.attempts[name] or 0) > 0 then
                Logger.info(self._component_name, "Сброс счетчика попыток для %s (стабильная работа)", name)
                s.recovery.attempts[name] = nil
            end
        end

        local needs_recovery = false
        local reason = ""

        -- 2. Проверка "Тишины" (Auto-recover)
        if settings.auto_recover.enabled and health.state == BaseMonitor.STATE.RUNNING then
            if now - (health.last_update or 0) > settings.auto_recover.interval then
                needs_recovery = true
                reason = "silence"
            end
        end

        -- 3. Проверка "Здоровья" (Watchdog) - только если монитор не молчит
        if not needs_recovery and settings.watchdog.enabled and health.state == BaseMonitor.STATE.RUNNING then
            -- Используем новый метод check_infrastructure_health()
            local is_healthy = monitor.check_infrastructure_health and monitor:check_infrastructure_health()
            if is_healthy == false then
                needs_recovery = true
                reason = "watchdog"
            end
        end

        -- 4. Выполнение восстановления
        if needs_recovery then
            local ok = self:_perform_recovery(name, monitor, class, reason, now)
            if ok then
                recovered = recovered + 1
            else
                failed = failed + 1
            end
        end

        ::next_monitor::
    end

    return recovered, failed
end

--- Выполняет процедуру восстановления монитора
--- @private
--- @param name string Имя монитора
--- @param monitor any Текущий экземпляр
--- @param class table Класс для пересоздания
--- @param reason string Причина ("silence" или "watchdog")
--- @param now number Текущее время
--- @return boolean Статус выполнения
function BaseRepository:_perform_recovery(name, monitor, class, reason, now)
    local s = self._state
    local settings = s.settings
    
    local attempts = (s.recovery.attempts[name] or 0) + 1
    local max_attempts = (reason == "watchdog") and settings.watchdog.max_attempts or settings.auto_recover.max_attempts

    if attempts > max_attempts then
        Logger.error(self._component_name,
            "[%s] Превышен лимит восстановления (%d/%d, причина: %s). Остановка.",
            name, attempts - 1, max_attempts, reason)
        
        s.stats.limit_reached = s.stats.limit_reached + 1
        self:_emit_event(EVENTS.RECOVERY_LIMIT, name, { attempts = attempts - 1, reason = reason })
        
        if monitor.pause then monitor:pause() end
        return false
    end

    Logger.warning(self._component_name,
        "[%s] Попытка восстановления (%d/%d, причина: %s)",
        name, attempts, max_attempts, reason)
    
    self:_emit_event(EVENTS.RECOVERY_ATTEMPT, name, { attempt = attempts, max = max_attempts, reason = reason })

    -- АТОМАРНОЕ ВОССТАНОВЛЕНИЕ (Shadow Copy)
    -- 1. Вызов хука для инфраструктурных действий (restart stream/adapter)
    local ok = self:_on_before_recreate(name, reason)
    if not ok then
        Logger.error(self._component_name, "[%s] Хук восстановления вернул ошибку", name)
        return false
    end

    -- 2. Получение конфига и пересоздание объекта
    local config = monitor.get_config and monitor:get_config()
    if config and class.new then
        local new_monitor = class.new(config)
        
        if new_monitor and new_monitor.start and new_monitor:start() then
            -- Успех: заменяем старый на новый (unregister сам вызовет destroy)
            self:unregister(name, true)
            self:register(name, new_monitor, class)
            
            s.recovery.attempts[name] = attempts
            s.recovery.last_success[name] = now
            
            s.stats.total_recovered = s.stats.total_recovered + 1
            Logger.info(self._component_name, "[%s] Монитор успешно восстановлен", name)
            self:_emit_event(EVENTS.RECOVERY_SUCCESS, name, { attempt = attempts, reason = reason })
            return true
        else
            s.stats.total_failed = s.stats.total_failed + 1
            s.recovery.attempts[name] = attempts
            Logger.error(self._component_name, "[%s] Не удалось запустить новый экземпляр", name)
            self:_emit_event(EVENTS.RECOVERY_FAILED, name, { attempt = attempts, reason = reason, error = "start_failed" })
            return false
        end
    else
        s.stats.total_failed = s.stats.total_failed + 1
        s.recovery.attempts[name] = attempts
        Logger.error(self._component_name, "[%s] Отсутствует конфиг или класс для пересоздания", name)
        return false
    end
end

--- Обновляет настройки репозитория (лимиты, интервалы, флаги)
--- @param params table Таблица параметров
--- @return boolean Статус выполнения
function BaseRepository:update_settings(params)
    if type(params) ~= "table" then return false end
    local s = self._state
    local settings = s.settings
    local changed_interval = false

    -- 1. Auto-recover settings
    if params.auto_recover_enabled ~= nil then settings.auto_recover.enabled = params.auto_recover_enabled end
    if params.auto_recover_interval ~= nil then settings.auto_recover.interval = params.auto_recover_interval end
    if params.auto_recover_max_attempts ~= nil then settings.auto_recover.max_attempts = params.auto_recover_max_attempts end
    if params.auto_recover_cooldown ~= nil then settings.auto_recover.cooldown = params.auto_recover_cooldown end

    -- 2. Watchdog settings
    if params.watchdog_enabled ~= nil then settings.watchdog.enabled = params.watchdog_enabled end
    if params.watchdog_max_attempts ~= nil then settings.watchdog.max_attempts = params.watchdog_max_attempts end
    if params.watchdog_interval ~= nil then
        if params.watchdog_interval ~= settings.watchdog.interval then
            settings.watchdog.interval = params.watchdog_interval
            changed_interval = true
        end
    end

    -- 3. Обновление задачи в планировщике при изменении интервала
    if changed_interval and self._maintenance_task_id then
        local scheduler = Scheduler and Scheduler.get_instance()
        if scheduler then
            scheduler:set_task_interval(self._maintenance_task_id, settings.watchdog.interval)
        end
    end

    Logger.info(self._component_name, "Настройки репозитория обновлены")
    return true
end

--- Включает механизм Watchdog
function BaseRepository:enable_watchdog()
    self._state.settings.watchdog.enabled = true
    Logger.info(self._component_name, "Watchdog включен")
end

--- Выключает механизм Watchdog
function BaseRepository:disable_watchdog()
    self._state.settings.watchdog.enabled = false
    Logger.info(self._component_name, "Watchdog выключен")
end

--- Регистрирует новый объект в репозитории
--- @param name string Имя объекта
--- @param instance any Экземпляр объекта
--- @param class? table Класс (мета-таблица) объекта для автовосстановления
--- @return boolean success true если объект зарегистрирован, false если уже существует
function BaseRepository:register(name, instance, class)
    local s = self._state
    if s.monitors[name] then
        Logger.warning(self._component_name, "Объект '%s' уже зарегистрирован.", name)
        return false
    end

    s.stats.active = s.stats.active + 1
    s.monitors[name] = instance
    if class then
        s.classes[name] = class
    end

    Logger.debug(self._component_name, "Объект '%s' зарегистрирован.", name)
    return true
end

--- Удаляет объект из репозитория и останавливает его
--- @param name string Имя объекта
--- @param force? boolean Принудительная остановка
--- @return table|nil Оригинальная конфигурация при успехе, иначе nil
function BaseRepository:unregister(name, force)
    local instance = self._state.monitors[name]
    if not instance then
        Logger.error(self._component_name, "unregister: объект '%s' не найден", name)
        return nil
    end

    local config = self:_destroy_instance(name, instance, force == true)
    if not config then
        Logger.error(self._component_name, "unregister: не удалось уничтожить объект '%s'", name)
    end
    
    return config
end

--- Находит объект по имени
--- @param name string Имя объекта
--- @return any|nil Экземпляр объекта или nil
function BaseRepository:find(name)
    return self._state.monitors[name]
end

--- Возвращает список всех объектов
--- @return table<string, any> Таблица объектов
function BaseRepository:get_all()
    return self._state.monitors
end

--- Возвращает количество активных объектов
--- @return number Количество объектов
function BaseRepository:count()
    return self._state.stats.active
end

--- Выполняет принудительный запуск цикла обслуживания (для тестов или API)
--- @return number Количество восстановленных
--- @return number Количество неудачных
function BaseRepository:auto_recover()
    return self:_maintenance_tick()
end

--- Включает автономное восстановление через планировщик
--- @param interval? number Интервал восстановления
function BaseRepository:enable_auto_recovery(interval)
    local s = self._state
    s.settings.auto_recover.enabled = true
    if interval then
        s.settings.auto_recover.interval = interval
    end
    Logger.info(self._component_name, "Автономное восстановление (Auto-recover) включено")
end

--- Выключает автономное восстановление
function BaseRepository:disable_auto_recovery()
    self._state.settings.auto_recover.enabled = false
    Logger.info(self._component_name, "Автономное восстановление (Auto-recover) выключено")
end

--- Возвращает детальную статистику репозитория
--- @return table Статистика (active, recovered, failed, limit_reached)
function BaseRepository:get_stats()
    local s = self._state
    return {
        component = self._component_name,
        active_count = s.stats.active,
        total_recovered = s.stats.total_recovered,
        total_failed = s.stats.total_failed,
        limit_reached_count = s.stats.limit_reached,
        last_check = s.recovery.last_check,
        is_autonomous = s.recovery.task_id ~= nil,
        health_score = self:get_health_score()
    }
end

--- Рассчитывает индекс здоровья (Health Score) всех мониторов в репозитории.
--- Индекс представляет собой процент мониторов в состоянии RUNNING.
--- @return number Score от 0 до 100
function BaseRepository:get_health_score()
    local s = self._state
    if s.stats.active == 0 then return 100 end

    local running_count = 0
    for _, monitor in pairs(s.monitors) do
        if monitor.get_state and monitor:get_state() == BaseMonitor.STATE.RUNNING then
            running_count = running_count + 1
        end
    end

    return (running_count / s.stats.active) * 100
end

--- Останавливает и удаляет все объекты в репозитории.
--- Используется при завершении работы системы.
function BaseRepository:shutdown()
    Logger.info(self._component_name, "Остановка репозитория: завершение работы %d мониторов", self._state.stats.active)
    
    self:disable_auto_recovery()
    self:disable_watchdog()

    if self._maintenance_task_id then
        local scheduler = Scheduler and Scheduler.get_instance()
        if scheduler then scheduler:remove_task(self._maintenance_task_id) end
        self._maintenance_task_id = nil
    end

    local names = {}
    for name in pairs(self._state.monitors) do
        names[#names + 1] = name
    end

    for _, name in ipairs(names) do
        self:unregister(name, true)
    end

    collectgarbage()
end

return BaseRepository
