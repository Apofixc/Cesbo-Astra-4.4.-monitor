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
local collectgarbage = _G.collectgarbage
local tostring = _G.tostring

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

--- @class Scheduler
--- @field private _tasks table<string, SchedulerTask> Реестр зарегистрированных задач
--- @field private _timer any|nil Системный таймер Astra
--- @field private _active boolean Флаг работы планировщика
--- @field private _task_count number Общее количество добавленных задач (для балансировки)
--- @field private _memory_limit_kb number Лимит памяти для автоматической очистки
--- @field private _current_interval number Текущий интервал таймера
--- @field private _next_tick_at number Время следующего ожидаемого тика
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
    self._active = true
    self._task_count = 0
    self._memory_limit_kb = DEFAULT_MEMORY_LIMIT_KB
    self._current_interval = 1
    self._next_tick_at = os_time() + 1

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
        -- Выполняет сборку мусора и сброс логов
        self:add_task("gc_maintenance", function()
            local mem_kb = collectgarbage("count")

            if mem_kb > self._memory_limit_kb then
                Logger.warn(COMPONENT_NAME,
                    "Превышен лимит памяти (%d KB > %d KB). Запуск полного GC.",
                    mem_kb, self._memory_limit_kb)

                -- Очистка пулов таблиц перед GC для максимального эффекта
                if TablePool and TablePool.clear_all then
                    TablePool.clear_all()
                end

                collectgarbage("collect")
            else
                -- Выполняем небольшой шаг сборки мусора для поддержания стабильности
                collectgarbage("step", 50)
            end

            -- Сброс накопленных логов (Batch Logging)
            if Logger and Logger.flush then
                Logger.flush()
            end
        end, 60)

        Logger.info(COMPONENT_NAME, "Планировщик инициализирован (Timer: OK, GC Limit: %d KB)", self._memory_limit_kb)
    else
        Logger.error(COMPONENT_NAME, "Критическая ошибка: зависимость Astra 'timer' не найдена!")
    end
end

--- Выполняет одну конкретную задачу
--- @param id string Идентификатор задачи
--- @param task SchedulerTask Объект задачи
--- @param now number Текущее время (os.time)
--- @private
function Scheduler:_run_task(id, task, now)
    local start_clock = os_clock()
    local ok, err = pcall(task.callback)
    local duration = os_clock() - start_clock

    if not ok then
        Logger.error(COMPONENT_NAME, "Ошибка при выполнении задачи '%s': %s", id, tostring(err))
    end

    -- Мониторинг производительности: предупреждаем, если задача блокирует поток
    if duration > 0.1 then -- 100ms
        Logger.warn(COMPONENT_NAME,
            "Задача '%s' выполнялась слишком долго: %.3f сек (возможна блокировка стриминга)", 
            id, duration)
    end

    task.last_run = now
    task.next_run = now + task.interval
end

--- Основной цикл планировщика, вызываемый каждую секунду
--- @private
function Scheduler:_tick()
    local now = os_time()
    local min_next_run = now + 3600 -- По умолчанию через час

    -- Списки задач по приоритетам для упорядоченного выполнения
    local p1, p2, p3 = {}, {}, {}
    
    for id, task in pairs(self._tasks) do
        if task.active then
            if now >= task.next_run then
                local p = task.priority or 2
                if p == 1 then p1[#p1+1] = id
                elseif p == 3 then p3[#p3+1] = id
                else p2[#p2+1] = id end
            end
            if task.next_run < min_next_run then
                min_next_run = task.next_run
            end
        end
    end

    -- Выполнение в порядке приоритета
    -- Проверка на nil обязательна, так как задача могла быть удалена другой задачей в этом же тике
    for i = 1, #p1 do
        local t = self._tasks[p1[i]]
        if t then self:_run_task(p1[i], t, now) end
    end
    for i = 1, #p2 do
        local t = self._tasks[p2[i]]
        if t then self:_run_task(p2[i], t, now) end
    end
    for i = 1, #p3 do
        local t = self._tasks[p3[i]]
        if t then self:_run_task(p3[i], t, now) end
    end

    -- Adaptive Ticking: регулируем интервал таймера
    local wait_time = min_next_run - now
    local new_interval = 1
    if wait_time > 5 then
        new_interval = 5
    elseif wait_time > 1 then
        new_interval = wait_time
    end

    if new_interval ~= self._current_interval and self._timer then
        self._current_interval = new_interval
        -- В Astra API таймер может не поддерживать смену интервала на лету,
        -- поэтому мы просто полагаемся на то, что следующий тик будет через 1с,
        -- если API не позволяет пересоздать таймер эффективно.
        -- Но для архитектуры закладываем это здесь.
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

    local now = os_time()
    local interval_val = (interval and interval >= 1) and interval or 1

    -- Балансировка нагрузки (Load Balancing):
    -- Добавляем небольшой временной сдвиг (jitter) для новых задач на основе их порядкового номера.
    -- Это предотвращает ситуацию, когда множество задач с одинаковым интервалом 
    -- запускаются одновременно в одну и ту же секунду.
    local jitter = (options and options.immediate) and 0 or (self._task_count % interval_val)

    self._tasks[id] = {
        id = id,
        callback = callback,
        interval = interval_val,
        last_run = 0,
        next_run = now + jitter,
        active = true,
        priority = options and options.priority or 2
    }

    self._task_count = self._task_count + 1
    Logger.debug(COMPONENT_NAME, "Задача зарегистрирована: %s (интервал: %d сек, jitter: %d)", 
        id, interval_val, jitter)
end

--- Удаляет задачу из реестра
--- @param id string Идентификатор задачи
function Scheduler:remove_task(id)
    if self._tasks[id] then
        self._tasks[id] = nil
        self._task_count = self._task_count - 1
        Logger.debug(COMPONENT_NAME, "Задача удалена: %s", id)
    end
end

--- Приостанавливает выполнение задачи без её удаления
--- @param id string Идентификатор задачи
function Scheduler:pause_task(id)
    if self._tasks[id] then 
        self._tasks[id].active = false 
        Logger.debug(COMPONENT_NAME, "Задача приостановлена: %s", id)
    end
end

--- Возобновляет выполнение ранее приостановленной задачи
--- @param id string Идентификатор задачи
function Scheduler:resume_task(id)
    local task = self._tasks[id]
    if task then
        task.active = true
        task.next_run = os_time() -- Запустить при следующем тике планировщика
        Logger.debug(COMPONENT_NAME, "Задача возобновлена: %s", id)
    end
end

--- Полная остановка планировщика и освобождение системных ресурсов
function Scheduler:shutdown()
    self._active = false
    
    -- Закрытие системного таймера Astra
    if self._timer then
        if self._timer.close then self._timer:close() end
        self._timer = nil
    end
    
    self._tasks = {}
    Logger.info(COMPONENT_NAME, "Планировщик остановлен, ресурсы очищены")
    
    -- Принудительный запуск GC для очистки остатков
    collectgarbage()
end

return Scheduler
