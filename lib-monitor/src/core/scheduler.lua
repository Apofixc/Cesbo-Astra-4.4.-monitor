-- ===========================================================================
-- Модуль `core.scheduler`
--
-- Единый планировщик задач для системы мониторинга.
-- Использует один системный таймер Astra для выполнения всех периодических задач.
-- Реализует балансировку нагрузки (Load Balancing) для предотвращения пиковых нагрузок.
-- ===========================================================================

-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local type = type
local os_time = os.time
local table_insert = table.insert
local table_remove = table.remove
local pcall = pcall
local setmetatable = setmetatable

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Scheduler"

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

        -- Добавляем задачу активного управления памятью
        self:add_task("gc_maintenance", function()
            -- Выполняем небольшой шаг сборки мусора
            collectgarbage("step", 20)
        end, 2)

        Logger.info(COMPONENT_NAME, "Scheduler initialized with single Astra timer and GC maintenance")
    else
        Logger.error(COMPONENT_NAME, "Astra timer dependency not found!")
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
    Logger.debug(COMPONENT_NAME, "Task added: %s (interval: %ds)", id, interval_val)
end

--- Удаляет задачу из планировщика
--- @param id string ID задачи
function Scheduler:remove_task(id)
    if self._tasks[id] then
        self._tasks[id] = nil
        self._task_count = self._task_count - 1
        Logger.debug(COMPONENT_NAME, "Task removed: %s", id)
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
            local ok, err = pcall(task.callback)
            if not ok then
                Logger.error(COMPONENT_NAME, "Error in task %s: %s", id, tostring(err))
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
    Logger.info(COMPONENT_NAME, "Scheduler shutdown")
end

return Scheduler
