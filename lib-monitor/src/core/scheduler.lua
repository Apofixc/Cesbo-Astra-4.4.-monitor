-- ===========================================================================
-- Модуль `core.scheduler`
--
-- Единый планировщик задач для системы мониторинга.
-- Использует один системный таймер Astra для выполнения всех периодических задач.
-- Реализует бинарную кучу (Min-Heap) для эффективного управления тысячами задач.
-- ===========================================================================

-- 1. Стандартные Lua функции
local pairs = _G.pairs
local type = _G.type
local os_time = _G.os.time
local os_clock = _G.os.clock
local pcall = _G.pcall
local setmetatable = _G.setmetatable
local collectgarbage = _G.collectgarbage
local tostring = _G.tostring
local math_floor = _G.math.floor

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local TablePool = ModuleManager.get_module("utils.table_pool")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra
local timer = ModuleManager.get_global_dependency("timer")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Scheduler"

-- Кэшированные параметры для обслуживания памяти (по умолчанию 50MB)
local DEFAULT_MEMORY_LIMIT_KB = 50 * 1024

-- 5. Инициализация объектов и внутреннее состояние
--- @class SchedulerTask
--- @field id string Уникальный ID задачи
--- @field callback function Функция для выполнения
--- @field interval number Интервал выполнения в секундах
--- @field last_run number Время последнего запуска (os.time)
--- @field next_run number Время следующего запуска (os.time)
--- @field active boolean Флаг активности задачи
--- @field priority number Приоритет (1 - высокий, 2 - нормальный, 3 - низкий)
--- @field heap_idx number Индекс в бинарной куче

--- @class Scheduler
--- @field private _tasks table<string, SchedulerTask> Реестр зарегистрированных задач (по ID)
--- @field private _heap SchedulerTask[] Бинарная куча задач (Min-Heap по next_run)
--- @field private _timer any|nil Системный таймер Astra
--- @field private _active boolean Флаг работы планировщика
--- @field private _task_count number Общее количество добавленных задач
--- @field private _memory_limit_kb number Лимит памяти для автоматической очистки
--- @field private _current_interval number Текущий интервал таймера
local Scheduler = {}
Scheduler.__index = Scheduler

--- @type Scheduler|nil Единственный экземпляр планировщика
local instance = nil

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

--- Инициализирует планировщик и запускает основной цикл
--- @private
function Scheduler:_initialize()
    -- Группировка переменных состояния
    self._tasks = {}
    self._heap = {}
    self._active = true
    self._task_count = 0
    self._memory_limit_kb = DEFAULT_MEMORY_LIMIT_KB
    self._current_interval = 1

    -- Запуск основного цикла (раз в секунду)
    if timer then
        self._timer = timer({
            interval = self._current_interval,
            callback = function()
                if self._active then self:_tick() end
            end
        })

        -- Обновляем лимит памяти из конфигурации
        if MonitorConfig and MonitorConfig.MemoryLimitMb then
            self._memory_limit_kb = MonitorConfig.MemoryLimitMb * 1024
        end

        -- Регистрация системной задачи обслуживания (раз в минуту)
        self:add_task("gc_maintenance", function()
            local mem_kb = collectgarbage("count")

            if mem_kb > self._memory_limit_kb then
                Logger.warn(COMPONENT_NAME,
                    "Превышен лимит памяти (%d KB > %d KB). Запуск полного GC.",
                    mem_kb, self._memory_limit_kb)

                if TablePool and TablePool.clear_all then
                    TablePool.clear_all()
                end

                collectgarbage("collect")
            else
                collectgarbage("step", 50)
            end

            if Logger and Logger.flush then
                Logger.flush()
            end
        end, 60)

        Logger.info(COMPONENT_NAME, "Планировщик инициализирован (Min-Heap: OK, GC Limit: %d KB)", self._memory_limit_kb)
    else
        Logger.error(COMPONENT_NAME, "Критическая ошибка: зависимость Astra 'timer' не найдена!")
    end
end

--- Всплытие элемента в куче
--- @private
function Scheduler:_heap_up(idx)
    while idx > 1 do
        local parent = math_floor(idx / 2)
        if self._heap[idx].next_run < self._heap[parent].next_run then
            self._heap[idx], self._heap[parent] = self._heap[parent], self._heap[idx]
            self._heap[idx].heap_idx = idx
            self._heap[parent].heap_idx = parent
            idx = parent
        else
            break
        end
    end
end

--- Погружение элемента в куче
--- @private
function Scheduler:_heap_down(idx)
    local size = #self._heap
    while true do
        local left = idx * 2
        local right = left + 1
        local smallest = idx

        if left <= size and self._heap[left].next_run < self._heap[smallest].next_run then
            smallest = left
        end
        if right <= size and self._heap[right].next_run < self._heap[smallest].next_run then
            smallest = right
        end

        if smallest ~= idx then
            self._heap[idx], self._heap[smallest] = self._heap[smallest], self._heap[idx]
            self._heap[idx].heap_idx = idx
            self._heap[smallest].heap_idx = smallest
            idx = smallest
        else
            break
        end
    end
end

--- Выполняет одну конкретную задачу
--- @param task SchedulerTask Объект задачи
--- @param now number Текущее время (os.time)
--- @private
function Scheduler:_run_task(task, now)
    local start_clock = os_clock()
    local ok, err = pcall(task.callback)
    local duration = os_clock() - start_clock

    if not ok then
        Logger.error(COMPONENT_NAME, "Ошибка при выполнении задачи '%s': %s", task.id, tostring(err))
    end

    if duration > 0.1 then
        Logger.warn(COMPONENT_NAME,
            "Задача '%s' выполнялась слишком долго: %.3f сек", 
            task.id, duration)
    end

    task.last_run = now
    task.next_run = now + task.interval
    
    -- После обновления времени следующего запуска, перестраиваем кучу
    self:_heap_down(task.heap_idx)
end

--- Основной цикл планировщика
--- @private
function Scheduler:_tick()
    -- Оптимизация: быстрый выход если задач нет
    if #self._heap == 0 then return end

    local now = os_time()
    
    -- Выполняем все задачи, время которых пришло
    while #self._heap > 0 do
        local task = self._heap[1]
        if now >= task.next_run then
            if task.active then
                self:_run_task(task, now)
            else
                task.next_run = now + task.interval
                self:_heap_down(1)
            end
        else
            break
        end
    end

    -- Adaptive Ticking
    local min_next_run = (#self._heap > 0) and self._heap[1].next_run or (now + 3600)
    local wait_time = min_next_run - now
    local new_interval = 1
    
    if wait_time > 5 then
        new_interval = 5
    elseif wait_time > 1 then
        new_interval = wait_time
    end

    if new_interval ~= self._current_interval and self._timer then
        self._current_interval = new_interval
    end
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Возвращает единственный экземпляр Scheduler (Singleton)
--- @return Scheduler Экземпляр планировщика
function Scheduler.get_instance()
    if not instance then
        instance = setmetatable({}, Scheduler)
        instance:_initialize()
    end
    return instance
end

--- Регистрирует новую периодическую задачу
--- @param id string Уникальный идентификатор задачи
--- @param callback function Функция для выполнения
--- @param interval number Интервал выполнения в секундах (минимум 1)
--- @param options? table Дополнительные опции: { immediate: boolean, priority: number }
function Scheduler:add_task(id, callback, interval, options)
    if not id or type(callback) ~= "function" then 
        Logger.error(COMPONENT_NAME, "Попытка добавить некорректную задачу: %s", tostring(id))
        return 
    end

    -- Если задача с таким ID уже существует, удаляем её перед добавлением новой.
    -- Это предотвращает дублирование задач в куче при перерегистрации.
    if self._tasks[id] then
        self:remove_task(id)
    end

    local now = os_time()
    local interval_val = (interval and interval >= 1) and interval or 1
    local jitter = (options and options.immediate) and 0 or (self._task_count % interval_val)

    local task = {
        id = id,
        callback = callback,
        interval = interval_val,
        last_run = 0,
        next_run = now + jitter,
        active = true,
        priority = options and options.priority or 2,
        heap_idx = #self._heap + 1
    }

    self._tasks[id] = task
    self._heap[#self._heap + 1] = task
    self:_heap_up(#self._heap)

    self._task_count = self._task_count + 1
    Logger.debug(COMPONENT_NAME, "Задача зарегистрирована: %s (интервал: %d сек)", id, interval_val)
end

--- Удаляет задачу из реестра
--- @param id string Идентификатор задачи
function Scheduler:remove_task(id)
    local task = self._tasks[id]
    if task then
        local idx = task.heap_idx
        local size = #self._heap
        
        if idx < size then
            self._heap[idx] = self._heap[size]
            self._heap[idx].heap_idx = idx
            self._heap[size] = nil
            
            self:_heap_down(idx)
            if self._heap[idx] then self:_heap_up(idx) end
        else
            self._heap[size] = nil
        end

        self._tasks[id] = nil
        self._task_count = self._task_count - 1
        Logger.debug(COMPONENT_NAME, "Задача удалена: %s", id)
    end
end

--- Изменяет интервал выполнения существующей задачи
--- @param id string Идентификатор задачи
--- @param interval number Новый интервал в секундах
function Scheduler:set_task_interval(id, interval)
    local task = self._tasks[id]
    if task then
        local old_interval = task.interval
        task.interval = (interval and interval >= 1) and interval or 1
        
        local now = os_time()
        local remaining = task.next_run - now
        if remaining > task.interval then
            task.next_run = now + task.interval
            self:_heap_up(task.heap_idx)
        end
        
        Logger.debug(COMPONENT_NAME, "Интервал задачи '%s' изменен: %d -> %d сек", 
            id, old_interval, task.interval)
    end
end

--- Приостанавливает выполнение задачи
--- @param id string Идентификатор задачи
function Scheduler:pause_task(id)
    if self._tasks[id] then 
        self._tasks[id].active = false 
        Logger.debug(COMPONENT_NAME, "Задача приостановлена: %s", id)
    end
end

--- Возобновляет выполнение задачи
--- @param id string Идентификатор задачи
function Scheduler:resume_task(id)
    local task = self._tasks[id]
    if task then
        task.active = true
        task.next_run = os_time()
        self:_heap_up(task.heap_idx)
        Logger.debug(COMPONENT_NAME, "Задача возобновлена: %s", id)
    end
end

--- Полная остановка планировщика
function Scheduler:shutdown()
    self._active = false
    if self._timer then
        if self._timer.close then self._timer:close() end
        self._timer = nil
    end
    self._tasks = {}
    self._heap = {}
    Logger.info(COMPONENT_NAME, "Планировщик остановлен")
    collectgarbage()
end

return Scheduler
