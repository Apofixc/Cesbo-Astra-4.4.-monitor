-- ===========================================================================
-- Модуль `core.base_repository`
--
-- Базовый класс для репозиториев, управляющих жизненным циклом мониторов.
-- Обеспечивает регистрацию, поиск и атомарное автоматическое восстановление.
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

-- 3. Глобальные зависимости Astra
-- (Нет прямых зависимостей)

-- 4. Константы и конфигурации
local COMPONENT_NAME = "BaseRepository"
local DEFAULT_RECOVER_INTERVAL = 300
local DEFAULT_MAX_ATTEMPTS = 3

--- @class BaseRepository
--- @field protected _monitors table<string, any> Таблица активных объектов
--- @field protected _classes table<string, table> Таблица классов мониторов для автовосстановления
--- @field protected _recovery table Таблица состояния восстановления (попытки, таймеры)
--- @field protected _stats table Статистика репозитория
--- @field protected _component_name string Имя компонента для логирования
--- @field protected _auto_recover_task_id string|nil ID задачи в планировщике
local BaseRepository = {}
BaseRepository.__index = BaseRepository

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

--- Выполняет очистку ресурсов монитора при удалении
--- @param self BaseRepository
--- @param name string Имя монитора
--- @param instance any Экземпляр монитора
--- @param force boolean Флаг принудительной остановки
--- @return table|nil Конфигурация монитора
local function _destroy_instance(self, name, instance, force)
    -- Все мониторы наследуются от BaseMonitor и имеют метод destroy
    local config = instance.destroy and instance:destroy(force)
    if config then
        self._monitors[name] = nil
        self._classes[name] = nil
        self._recovery.attempts[name] = nil
        self._stats.active = self._stats.active - 1
        
        Logger.debug(self._component_name,
            "Объект '%s' удален и остановлен (принудительно: %s).",
            name, tostring(force))
        return config
    end
    return nil
end

-- ===========================================================================
-- Конструктор
-- ===========================================================================

--- Создает новый экземпляр базового репозитория
--- @param component_name string Имя компонента для логирования
--- @return BaseRepository
function BaseRepository.new(component_name)
    local self = setmetatable({}, BaseRepository)

    -- 5. Внутреннее состояние (Private State)
    
    -- Хранилище объектов
    self._monitors = {}          -- Активные экземпляры мониторов
    self._classes = {}           -- Классы (мета-таблицы) для пересоздания

    -- Состояние восстановления
    self._recovery = {
        attempts = {},           -- История попыток восстановления: name -> count
        last_check = 0           -- Время последней проверки auto_recover
    }

    -- Статистика и метаданные
    self._stats = {
        active = 0,              -- Текущее количество активных объектов
        total_recovered = 0,     -- Всего успешно восстановлено
        total_failed = 0         -- Всего неудачных попыток
    }

    self._component_name = component_name or COMPONENT_NAME
    self._auto_recover_task_id = nil

    -- Опциональная инициализация автономного мониторинга
    if MonitorConfig and MonitorConfig.AutoRecoverEnabled then
        self:enable_auto_recovery()
    end

    return self
end

-- ===========================================================================
-- Публичное API: Управление объектами
-- ===========================================================================

--- Регистрирует новый объект в репозитории
--- @param name string Имя объекта
--- @param instance any Экземпляр объекта
--- @param class? table Класс (мета-таблица) объекта для автовосстановления
function BaseRepository:register(name, instance, class)
    if self._monitors[name] then
        Logger.warn(self._component_name, "Объект '%s' уже зарегистрирован. Перезапись.", name)
    else
        self._stats.active = self._stats.active + 1
    end

    self._monitors[name] = instance
    if class then
        self._classes[name] = class
    end

    Logger.debug(self._component_name, "Объект '%s' зарегистрирован.", name)
end

--- Удаляет объект из репозитория и останавливает его
--- @param name string Имя объекта
--- @param force? boolean Принудительная остановка
--- @return table|nil Оригинальная конфигурация при успехе, иначе nil
function BaseRepository:unregister(name, force)
    local instance = self._monitors[name]
    if not instance then
        Logger.error(self._component_name, "unregister: объект '%s' не найден", name)
        return nil
    end

    local config = _destroy_instance(self, name, instance, force == true)
    if not config then
        Logger.error(self._component_name, "unregister: не удалось уничтожить объект '%s'", name)
    end
    
    return config
end

--- Находит объект по имени
--- @param name string Имя объекта
--- @return any|nil Экземпляр объекта или nil
function BaseRepository:find(name)
    return self._monitors[name]
end

--- Возвращает список всех объектов
--- @return table<string, any> Таблица объектов
function BaseRepository:get_all()
    return self._monitors
end

--- Возвращает количество активных объектов
--- @return number Количество объектов
function BaseRepository:count()
    return self._stats.active
end

-- ===========================================================================
-- Публичное API: Жизненный цикл и восстановление
-- ===========================================================================

--- Выполняет автоматическое восстановление зависших мониторов.
--- Реализует атомарный подход (Shadow Copy): сначала создаем новый, потом удаляем старый.
--- @return number recovered Количество восстановленных мониторов
--- @return number failed Количество неудачных попыток
function BaseRepository:auto_recover()
    local recovered = 0
    local failed = 0
    local now = os_time()
    self._recovery.last_check = now

    -- Создаем список имен для итерации
    local names = {}
    for name in pairs(self._monitors) do
        names[#names + 1] = name
    end

    local recover_interval = (MonitorConfig and MonitorConfig.AutoRecoverInterval) or DEFAULT_RECOVER_INTERVAL
    local max_attempts = (MonitorConfig and MonitorConfig.MaxRecoveryAttempts) or DEFAULT_MAX_ATTEMPTS

    for _, name in ipairs(names) do
        local monitor = self._monitors[name]
        local class = self._classes[name]

        if monitor and monitor.health_check and class then
            local health = monitor:health_check()

            -- Проверка на "зависшие" мониторы (RUNNING, но нет обновлений)
            if health.state == BaseMonitor.STATE.RUNNING and
               now - (health.last_update or 0) > recover_interval then

                local attempts = (self._recovery.attempts[name] or 0) + 1
                
                -- Проверка лимита попыток
                if attempts > max_attempts then
                    Logger.error(self._component_name,
                        "Превышен лимит попыток восстановления для %s (%d/%d). Монитор остановлен.",
                        name, attempts - 1, max_attempts)
                    
                    if monitor.pause then monitor:pause() end
                    goto next_monitor
                end

                Logger.warn(self._component_name,
                    "Попытка восстановления зависшего монитора: %s (попытка %d/%d)",
                    name, attempts, max_attempts)

                -- АТОМАРНОЕ ВОССТАНОВЛЕНИЕ (Shadow Copy)
                -- 1. Получаем текущий конфиг без удаления объекта
                local config = monitor.get_config and monitor:get_config()
                
                if config and class.new then
                    -- 2. Создаем новый экземпляр "в тени"
                    local new_monitor = class.new(config)
                    
                    -- 3. Пробуем запустить новый экземпляр
                    if new_monitor and new_monitor.start and new_monitor:start() then
                        -- 4. Только при успехе удаляем старый и регистрируем новый
                        self:unregister(name, true)
                        self:register(name, new_monitor, class)
                        
                        -- Сохраняем счетчик попыток (register его не трогает, unregister очистил)
                        self._recovery.attempts[name] = attempts
                        
                        recovered = recovered + 1
                        self._stats.total_recovered = self._stats.total_recovered + 1
                        Logger.info(self._component_name, "Монитор %s успешно восстановлен (атомарно)", name)
                    else
                        failed = failed + 1
                        self._stats.total_failed = self._stats.total_failed + 1
                        self._recovery.attempts[name] = attempts -- Засчитываем попытку даже при неудаче
                        Logger.error(self._component_name,
                            "Не удалось перезапустить новый экземпляр %s при восстановлении", name)
                    end
                else
                    failed = failed + 1
                    self._stats.total_failed = self._stats.total_failed + 1
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
    self._auto_recover_task_id = s:add_task(task_name, function()
        self:auto_recover()
    end, interval)

    Logger.info(self._component_name, "Автономное восстановление включено (интервал: %d сек)", interval)
end

--- Выключает автономное восстановление
function BaseRepository:disable_auto_recovery()
    if not Scheduler or not self._auto_recover_task_id then return end
    
    local s = Scheduler.get_instance()
    if s then
        s:remove_task(self._auto_recover_task_id)
        self._auto_recover_task_id = nil
        Logger.info(self._component_name, "Автономное восстановление выключено")
    end
end

--- Останавливает и удаляет все объекты в репозитории.
--- Используется при завершении работы системы.
function BaseRepository:shutdown()
    Logger.info(self._component_name, "Остановка репозитория: завершение работы %d мониторов", self._stats.active)
    
    self:disable_auto_recovery()

    local names = {}
    for name in pairs(self._monitors) do
        names[#names + 1] = name
    end

    for _, name in ipairs(names) do
        self:unregister(name, true)
    end

    collectgarbage()
end

return BaseRepository
