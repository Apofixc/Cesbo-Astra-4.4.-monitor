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

--- Настройки по умолчанию
local DEFAULT_RECOVER_INTERVAL = (MonitorConfig and MonitorConfig.AutoRecoverInterval) or 300
local DEFAULT_MAX_ATTEMPTS = (MonitorConfig and MonitorConfig.MaxRecoveryAttempts) or 3
local DEFAULT_COOLDOWN_TIME = (MonitorConfig and MonitorConfig.RecoveryCooldown) or 3600 -- 1 час стабильной работы для сброса попыток

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
--- @field protected _watchdog_task_id string|nil ID задачи Watchdog в планировщике
local BaseRepository = {}
BaseRepository.__index = BaseRepository

-- ===========================================================================
-- Внутренние функции (Private)
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
    if not dispatcher then return end

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
-- Конструктор
-- ===========================================================================

--- Создает новый экземпляр базового репозитория
--- @param component_name string Имя компонента для логирования
--- @return BaseRepository
function BaseRepository.new(component_name)
    local self = setmetatable({}, BaseRepository)

    -- Организация внутреннего состояния (Private State)
    self._state = {
        -- Хранилище объектов
        monitors = {},           -- Активные экземпляры мониторов: name -> instance
        classes = {},            -- Классы (мета-таблицы) для пересоздания: name -> class

        -- Состояние восстановления
        recovery = {
            attempts = {},       -- История попыток восстановления: name -> count
            last_success = {},   -- Время последнего успешного восстановления: name -> timestamp
            last_check = 0,      -- Время последней проверки auto_recover
            task_id = nil        -- ID задачи в планировщике
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
    self._watchdog_task_id = nil

    -- Опциональная инициализация автономного мониторинга
    if MonitorConfig and MonitorConfig.AutoRecoverEnabled then
        self:enable_auto_recovery()
    end

    return self
end

--- Выполняет проверку Watchdog для всех мониторов в репозитории
--- @protected
function BaseRepository:_watchdog_tick()
    local now = os_time()
    local s = self._state
    
    -- Глобальные настройки из конфига
    local enabled = MonitorConfig and MonitorConfig.WatchdogEnabled
    if not enabled then return end

    for name, monitor in pairs(s.monitors) do
        if monitor.get_status_table and monitor.get_state then
            local state = monitor:get_state()
            if state == BaseMonitor.STATE.RUNNING then
                local status = monitor:get_status_table()
                if status then
                    self:_check_monitor_watchdog(name, monitor, status, now)
                end
            end
        end
    end
end

--- Проверяет конкретный монитор (должно быть переопределено в наследниках)
--- @protected
--- @param name string Имя монитора
--- @param monitor any Экземпляр монитора
--- @param status table Текущий статус
--- @param now number Текущее время
function BaseRepository:_check_monitor_watchdog(name, monitor, status, now)
    -- Базовая реализация пустая
end

--- Включает механизм Watchdog
--- @param interval? number Интервал проверки в секундах
function BaseRepository:enable_watchdog(interval)
    local scheduler = Scheduler and Scheduler.get_instance()
    if not scheduler then return end

    interval = interval or 5
    local task_id = "watchdog_" .. self._component_name
    
    scheduler:add_task(task_id, function()
        self:_watchdog_tick()
    end, interval)
    
    self._watchdog_task_id = task_id
    Logger.info(self._component_name, "Watchdog включен (интервал: %d сек)", interval)
end

--- Выключает механизм Watchdog
function BaseRepository:disable_watchdog()
    local scheduler = Scheduler and Scheduler.get_instance()
    if scheduler and self._watchdog_task_id then
        scheduler:remove_task(self._watchdog_task_id)
        self._watchdog_task_id = nil
        Logger.info(self._component_name, "Watchdog выключен")
    end
end

-- ===========================================================================
-- Публичное API: Управление объектами
-- ===========================================================================

--- Регистрирует новый объект в репозитории
--- @param name string Имя объекта
--- @param instance any Экземпляр объекта
--- @param class? table Класс (мета-таблица) объекта для автовосстановления
function BaseRepository:register(name, instance, class)
    local s = self._state
    if s.monitors[name] then
        Logger.warn(self._component_name, "Объект '%s' уже зарегистрирован. Перезапись.", name)
    else
        s.stats.active = s.stats.active + 1
    end

    s.monitors[name] = instance
    if class then
        s.classes[name] = class
    end

    Logger.debug(self._component_name, "Объект '%s' зарегистрирован.", name)
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

-- ===========================================================================
-- Публичное API: Жизненный цикл и восстановление
-- ===========================================================================

--- Выполняет автоматическое восстановление зависших мониторов.
--- Реализует атомарный подход (Shadow Copy) и механизм Cooldown.
--- @return number recovered Количество восстановленных мониторов
--- @return number failed Количество неудачных попыток
function BaseRepository:auto_recover()
    local recovered = 0
    local failed = 0
    local now = os_time()
    local s = self._state
    s.recovery.last_check = now

    -- Создаем список имен для итерации
    local names = {}
    for name in pairs(s.monitors) do
        names[#names + 1] = name
    end

    local recover_interval = (MonitorConfig and MonitorConfig.AutoRecoverInterval) or DEFAULT_RECOVER_INTERVAL
    local max_attempts = (MonitorConfig and MonitorConfig.MaxRecoveryAttempts) or DEFAULT_MAX_ATTEMPTS
    local cooldown_time = (MonitorConfig and MonitorConfig.RecoveryCooldown) or DEFAULT_COOLDOWN_TIME

    for _, name in ipairs(names) do
        local monitor = s.monitors[name]
        local class = s.classes[name]

        if monitor and monitor.health_check and class then
            local health = monitor:health_check()

            -- Механизм Cooldown: если монитор долго работает стабильно, сбрасываем попытки
            local last_success = s.recovery.last_success[name] or 0
            if last_success > 0 and now - last_success > cooldown_time then
                if (s.recovery.attempts[name] or 0) > 0 then
                    Logger.info(self._component_name, "Сброс счетчика попыток для %s (Cooldown пройден)", name)
                    s.recovery.attempts[name] = nil
                end
            end

            -- Проверка на "зависшие" мониторы (RUNNING, но нет обновлений)
            if health.state == BaseMonitor.STATE.RUNNING and
               now - (health.last_update or 0) > recover_interval then

                local attempts = (s.recovery.attempts[name] or 0) + 1
                
                -- Проверка лимита попыток
                if attempts > max_attempts then
                    Logger.error(self._component_name,
                        "Превышен лимит попыток восстановления для %s (%d/%d). Монитор остановлен.",
                        name, attempts - 1, max_attempts)
                    
                    s.stats.limit_reached = s.stats.limit_reached + 1
                    self:_emit_event(EVENTS.RECOVERY_LIMIT, name, { attempts = attempts - 1 })
                    
                    if monitor.pause then monitor:pause() end
                    goto next_monitor
                end

                Logger.warn(self._component_name,
                    "Попытка восстановления зависшего монитора: %s (попытка %d/%d)",
                    name, attempts, max_attempts)
                
                self:_emit_event(EVENTS.RECOVERY_ATTEMPT, name, { attempt = attempts, max = max_attempts })

                -- АТОМАРНОЕ ВОССТАНОВЛЕНИЕ (Shadow Copy)
                local config = monitor.get_config and monitor:get_config()
                
                if config and class.new then
                    local new_monitor = class.new(config)
                    
                    if new_monitor and new_monitor.start and new_monitor:start() then
                        -- Успех: заменяем старый на новый
                        self:unregister(name, true)
                        self:register(name, new_monitor, class)
                        
                        s.recovery.attempts[name] = attempts
                        s.recovery.last_success[name] = now
                        
                        recovered = recovered + 1
                        s.stats.total_recovered = s.stats.total_recovered + 1
                        
                        Logger.info(self._component_name, "Монитор %s успешно восстановлен (атомарно)", name)
                        self:_emit_event(EVENTS.RECOVERY_SUCCESS, name, { attempt = attempts })
                    else
                        -- Неудача старта нового экземпляра
                        failed = failed + 1
                        s.stats.total_failed = s.stats.total_failed + 1
                        s.recovery.attempts[name] = attempts
                        
                        Logger.error(self._component_name,
                            "Не удалось перезапустить новый экземпляр %s при восстановлении", name)
                        self:_emit_event(EVENTS.RECOVERY_FAILED, name, { attempt = attempts, error = "start_failed" })
                    end
                else
                    failed = failed + 1
                    s.stats.total_failed = s.stats.total_failed + 1
                    Logger.error(self._component_name,
                        "Не удалось восстановить монитор %s: отсутствует конфиг или класс", name)
                end
            end
        end
        ::next_monitor::
    end

    return recovered, failed
end

--- Включает автономное восстановление через планировщик
--- @param interval? number Интервал проверки в секундах
function BaseRepository:enable_auto_recovery(interval)
    if not Scheduler then return end
    
    local s = Scheduler.get_instance()
    if not s then return end

    interval = interval or (MonitorConfig and MonitorConfig.AutoRecoverInterval) or DEFAULT_RECOVER_INTERVAL
    
    local task_name = "auto_recover_" .. self._component_name
    self._state.recovery.task_id = s:add_task(task_name, function()
        self:auto_recover()
    end, interval)

    Logger.info(self._component_name, "Автономное восстановление включено (интервал: %d сек)", interval)
end

--- Выключает автономное восстановление
function BaseRepository:disable_auto_recovery()
    local s_mgr = Scheduler and Scheduler.get_instance()
    local task_id = self._state.recovery.task_id
    
    if s_mgr and task_id then
        s_mgr:remove_task(task_id)
        self._state.recovery.task_id = nil
        Logger.info(self._component_name, "Автономное восстановление выключено")
    end
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
