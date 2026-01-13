-- ===========================================================================
-- Модуль `core.scheduler`
--
-- Единый планировщик задач для системы мониторинга.
-- Использует один системный таймер Astra для выполнения всех периодических задач.
-- Реализует балансировку нагрузки (Load Balancing) для предотвращения пиковых нагрузок.
-- ===========================================================================

-- 1. Стандартные Lua функции
local pairs = _G.pairs
local type = _G.type
local os_time = _G.os.time
local os_clock = _G.os.clock
local pcall = _G.pcall
local setmetatable = _G.setmetatable

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local TablePool = ModuleManager.get_module("utils.table_pool")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Scheduler"

-- Кэшированные параметры для обслуживания памяти
local memory_limit_kb = 50 * 1024

--- @class SchedulerTask
--- @field id string Уникальный ID задачи
--- @field callback function Функция для выполнения
--- @field interval number Интервал выполнения в секундах
--- @field last_run number Время последнего запуска
--- @field next_run number Время следующего запуска
--- @field active boolean Флаг активности

--- @class Scheduler
--- @field private _tasks table<string, SchedulerTask> Список зарегистрированных задач
--- @field private _timer any|nil Системный таймер Astra
--- @field private _active boolean Флаг работы планировщика
local Scheduler = {}
Scheduler.__index = Scheduler

local instance = nil

--- Возвращает единственный экземпляр Scheduler (Singleton)
--- @return Scheduler Экземпляр планировщика
function Scheduler.get_instance()
    if not instance then
        instance = setmetatable({}, Scheduler)
        instance:initialize()
    end
    return instance
end

--- Инициализирует планировщик
--- @private
function Scheduler:initialize()
    self._tasks = {}
    self._active = true
    self._task_count = 0

    -- Запуск основного цикла (раз в секунду)
    if timer then
        self._timer = timer({
            interval = 1,
            callback = function()
                if self._active then self:_tick() end
            end
        })

        -- Обновляем кэшированный лимит памяти
        if MonitorConfig and MonitorConfig.MemoryLimitMb then
            memory_limit_kb = MonitorConfig.MemoryLimitMb * 1024
        end

        -- Добавляем задачу активного управления памятью (раз в минуту)
        self:add_task("gc_maintenance", function()
            local mem_kb = collectgarbage("count")

            if mem_kb > memory_limit_kb then
                Logger.warn(COMPONENT_NAME,
                    "Превышен лимит памяти (%d KB > %d KB). Запуск полного GC.",
                    mem_kb, memory_limit_kb)

                -- Очистка пулов таблиц перед GC для максимального эффекта
                if TablePool and TablePool.clear_all then
                    TablePool.clear_all()
                end

                collectgarbage("collect")
            else
                -- Выполняем небольшой шаг сборки мусора
                collectgarbage("step", 50)
            end

            -- Сброс накопленных логов (Batch Logging)
            if Logger and Logger.flush then
                Logger.flush()
            end
        end, 60)

        Logger.info(COMPONENT_NAME, "Планировщик инициализирован с системным таймером Astra и адаптивным GC")
    else
        Logger.error(COMPONENT_NAME, "Зависимость Astra timer не найдена!")
    end
end

--- Регистрирует новую задачу в планировщике
--- @param id string Уникальный идентификатор задачи
--- @param callback function Функция для выполнения
--- @param interval number Интервал в секундах
--- @param options? table [Дополнительные опции: immediate (запустить сразу)]
function Scheduler:add_task(id, callback, interval, options)
    if not id or type(callback) ~= "function" then return end

    local now = os_time()
    local interval_val = interval or 1
    if interval_val < 1 then interval_val = 1 end

    -- Балансировка нагрузки: добавляем небольшой случайный сдвиг для новых задач,
    -- чтобы они не стартовали одновременно.
    local jitter = (options and options.immediate) and 0 or (self._task_count % interval_val)

    self._tasks[id] = {
        id = id,
        callback = callback,
        interval = interval_val,
        last_run = 0,
        next_run = now + jitter,
        active = true
    }

    self._task_count = self._task_count + 1
    Logger.debug(COMPONENT_NAME, "Задача добавлена: %s (интервал: %d сек)", id, interval_val)
end

--- Удаляет задачу из планировщика
--- @param id string ID задачи
function Scheduler:remove_task(id)
    if self._tasks[id] then
        self._tasks[id] = nil
        self._task_count = self._task_count - 1
        Logger.debug(COMPONENT_NAME,
            "Задача удалена: %s", id)
    end
end

--- Приостанавливает выполнение задачи
--- @param id string ID задачи
function Scheduler:pause_task(id)
    if self._tasks[id] then self._tasks[id].active = false end
end

--- Возобновляет выполнение задачи
--- @param id string ID задачи
function Scheduler:resume_task(id)
    if self._tasks[id] then
        self._tasks[id].active = true
        self._tasks[id].next_run = os_time() -- Запустить при следующем тике
    end
end

--- Основной цикл планировщика
--- @private
function Scheduler:_tick()
    local now = os_time()

    -- Собираем задачи, готовые к выполнению
    for id, task in pairs(self._tasks) do
        if task.active and now >= task.next_run then
            local start_clock = os_clock()
            local ok, err = pcall(task.callback)
            local duration = os_clock() - start_clock

            if not ok then
                Logger.error(COMPONENT_NAME, "Ошибка в задаче %s: %s", id, tostring(err))
            end

            -- Проверка времени выполнения (Load Balancing / Performance Monitoring)
            if duration > 0.1 then -- 100ms
                Logger.warn(COMPONENT_NAME,
                    "Задача %s выполнялась слишком долго: %.3f сек", id, duration)
            end

            task.last_run = now
            task.next_run = now + task.interval
        end
    end
end

--- Останавливает планировщик и очищает ресурсы
function Scheduler:shutdown()
    self._active = false
    if self._timer then
        if self._timer.close then self._timer:close() end
        self._timer = nil
    end
    self._tasks = {}
    Logger.info(COMPONENT_NAME, "Планировщик остановлен")
    collectgarbage()
end

return Scheduler
