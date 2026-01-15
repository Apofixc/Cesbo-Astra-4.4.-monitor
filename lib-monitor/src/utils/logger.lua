-- 1. Стандартные Lua функции
local ipairs = _G.ipairs
local os_time = _G.os.time
local pcall = _G.pcall
local select = _G.select
local string_format = _G.string.format
local table_insert = _G.table.insert
local table_remove = _G.table.remove
local tostring = _G.tostring
local unpack = _G.table.unpack

-- 2. Функции из ModuleManager.get_module()
local MonitorConfig = nil -- Кэшируется при первом обращении
local TablePool = nil -- Кэшируется при первом обращении

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local log = ModuleManager.get_global_dependency("log")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local LOG_LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    NONE = 5
}

-- Внутреннее состояние для контекстного хранения ошибок
local last_errors = {}
local context_stack = {}
local current_context_id = nil
local context_counter = 0
local active_contexts = 0

-- Список компонентов для ограничения размера _context_buffer
local component_list = {}
local MAX_COMPONENTS = 100

-- Очередь для пакетной записи логов
local log_queue = {}
local MAX_LOG_QUEUE_SIZE = 200

-- Кэширование уровня логирования и конфига
local cached_log_level = nil
local cached_log_format = nil
local cached_log_buffer_size = 0
local cached_log_batch_enabled = false
local last_config_refresh = 0
local CONFIG_REFRESH_INTERVAL = 5 -- секунд

-- 5. Инициализация объектов из загруженных модулей

--- Возвращает модуль конфигурации (ленивая загрузка для избежания циклических зависимостей)
--- @return MonitorConfig|nil
local function get_monitor_config()
    if MonitorConfig then return MonitorConfig end

    local success, config = pcall(ModuleManager.get_module, "monitor_config")
    if success and config and type(config) == "table" then
        MonitorConfig = config
        return MonitorConfig
    end
    return nil
end

--- Возвращает модуль TablePool (ленивая загрузка)
--- @return TablePool|nil
local function get_table_pool()
    if TablePool then return TablePool end

    local success, pool = pcall(ModuleManager.get_module, "table_pool")
    if success and pool and type(pool) == "table" then
        TablePool = pool
        return TablePool
    end
    return nil
end

--- @class Logger
--- @field private last_errors table<number, string> Хранилище последних ошибок по контекстам
--- @field private context_stack table<number, number> Стек контекстов
--- @field private current_context_id number|nil Текущий идентификатор контекста
--- @field _context_buffer table<string, table> Буфер логов для диагностики
--- @field _buffer_size number Максимальный размер буфера
local Logger = {}

-- Буфер логов для диагностики
Logger._context_buffer = {}
Logger._buffer_size = 1000

--- Обновляет кэшированный уровень логирования и сбрасывает кэш конфигурации
function Logger.refresh_log_level()
    local config = get_monitor_config()
    if config then
        cached_log_level = LOG_LEVELS[config.LogLevel] or LOG_LEVELS.INFO
        cached_log_format = config.LogFormat or "TEXT"
        cached_log_buffer_size = config.LogBufferSize or 0
        cached_log_batch_enabled = config.LogBatchEnabled or false
    else
        cached_log_level = LOG_LEVELS.INFO
        cached_log_format = "TEXT"
        cached_log_buffer_size = 0
        cached_log_batch_enabled = false
    end
end

local function get_current_level()
    local now = os_time()
    if not cached_log_level or now - last_config_refresh > CONFIG_REFRESH_INTERVAL then
        Logger.refresh_log_level()
        last_config_refresh = now
    end
    return cached_log_level
end

local function should_log(level)
    return level >= get_current_level()
end

--- Добавляет запись в кольцевой буфер логов
--- @param level string Уровень лога
--- @param component string Имя компонента
--- @param message string Текст сообщения
--- @param context_id? number ID контекста
--- @param now? number Текущее время
function Logger.buffer_log(level, component, message, context_id, now)
    if not Logger._context_buffer[component] then
        -- Ограничение количества отслеживаемых компонентов (защита от утечек)
        if #component_list >= MAX_COMPONENTS then
            local old_comp = table_remove(component_list, 1)
            Logger.clear_component_buffer(old_comp)
        end
        table_insert(component_list, component)
        Logger._context_buffer[component] = {}
    end

    local buffer = Logger._context_buffer[component]

    local pool = get_table_pool()
    local entry = pool and pool.get("log_entry") or {}
    entry.timestamp = now or os_time()
    entry.level = level
    entry.message = message
    entry.context_id = context_id

    table_insert(buffer, entry)

    -- Ограничение размера буфера (FIFO)
    if #buffer > Logger._buffer_size then
        local old = table_remove(buffer, 1)
        if pool and old then
            pool.release(old, "log_entry")
        end
    end
end

--- Полностью очищает буфер логов для указанного компонента
--- @param component string Имя компонента
function Logger.clear_component_buffer(component)
    local buffer = Logger._context_buffer[component]
    if not buffer then return end

    local pool = get_table_pool()
    for i = 1, #buffer do
        local entry = buffer[i]
        if pool and entry then
            pool.release(entry, "log_entry")
        end
        buffer[i] = nil
    end
    Logger._context_buffer[component] = nil

    -- Удаляем из списка компонентов
    for i = 1, #component_list do
        if component_list[i] == component then
            table_remove(component_list, i)
            break
        end
    end
end

--- Возвращает содержимое буфера логов
--- @param component string Имя компонента
--- @param limit? number Лимит записей
--- @return table Список записей
function Logger.get_buffer(component, limit)
    local buffer = Logger._context_buffer[component]
    if not buffer then return {} end

    if limit and #buffer > limit then
        local result = {}
        for i = #buffer - limit + 1, #buffer do
            table_insert(result, buffer[i])
        end
        return result
    end

    return buffer
end

--- Сбрасывает накопленные логи в системный лог Astra
function Logger.flush()
    if #log_queue == 0 then return end

    local current_queue = log_queue
    log_queue = {}

    local pool = get_table_pool()
    for _, item in ipairs(current_queue) do
        local lower_level = item.level:lower()
        local message = item.message
        if log and type(log) == "table" and type(log[lower_level]) == "function" then
            pcall(log[lower_level], message)
        else
            print(string_format("[%s] %s", item.level, message))
        end

        if pool then
            pool.release(item, "log_entry")
        end
    end
end

--- Внутренняя функция для записи лога
--- @private
local function write_log(level_name, component, format_str, ...)
    local level = LOG_LEVELS[level_name]
    local is_error = (level_name == "ERROR")

    -- Оптимизация: Проверяем уровень ДО формирования строки
    local should_log_msg = should_log(level)
    if not should_log_msg and not (is_error and current_context_id) then
        return
    end

    local msg
    if select("#", ...) > 0 then
        msg = string_format(format_str, ...)
    else
        msg = format_str
    end

    if is_error and current_context_id then
        last_errors[current_context_id] = msg
        for i = 1, #context_stack do
            last_errors[context_stack[i]] = msg
        end
    end

    local now = os_time()

    -- Буферизация (если включена в конфиге)
    if cached_log_buffer_size > 0 then
        Logger._buffer_size = cached_log_buffer_size
        Logger.buffer_log(level_name, component, msg, current_context_id, now)
    end

    if should_log_msg then
        local use_json = (cached_log_format == "JSON")
        local raw_msg = msg

        if use_json then
            local pool = get_table_pool()
            local log_data = pool and pool.get("log_data") or {}
            log_data.timestamp = now
            log_data.level = level_name
            log_data.component = component
            log_data.message = raw_msg
            log_data.context_id = current_context_id

            msg = json_encode(log_data)

            if pool then
                pool.release(log_data, "log_data")
            end
        else
            msg = string_format("[%s] %s", component, raw_msg)
        end

        -- Пакетная запись (Batch Logging)
        if cached_log_batch_enabled then
            local pool = get_table_pool()
            local item = pool and pool.get("log_entry") or {}
            item.level = level_name
            item.message = msg

            if #log_queue < MAX_LOG_QUEUE_SIZE then
                table_insert(log_queue, item)
            else
                -- Если очередь переполнена, сбрасываем немедленно
                Logger.flush()
                table_insert(log_queue, item)
            end
        else
            -- Обычная немедленная запись
            local lower_level = level_name:lower()
            if log and type(log) == "table" and type(log[lower_level]) == "function" then
                local ok, err = pcall(log[lower_level], msg)
                if not ok then
                    print(string_format("[ОШИБКА ЛОГГЕРА] Не удалось записать в лог Astra: %s", tostring(err)))
                end
            else
                print(string_format("[%s] %s", level_name, msg))
            end
        end
    end
end

--- Логирует сообщение с уровнем INFO
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.info(component, format_str, ...)
    write_log("INFO", component, format_str, ...)
end

--- Логирует сообщение с уровнем ERROR и сохраняет в контекст, если он активен
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.error(component, format_str, ...)
    write_log("ERROR", component, format_str, ...)
end

--- Логирует сообщение с уровнем DEBUG
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.debug(component, format_str, ...)
    write_log("DEBUG", component, format_str, ...)
end

--- Логирует сообщение с уровнем WARN
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.warn(component, format_str, ...)
    write_log("WARN", component, format_str, ...)
end

--- Выполняет функцию в контексте отслеживания ошибок
--- @param func function Функция для выполнения
--- @param ... any Аргументы функции
--- @return boolean success Статус выполнения
--- @return any|string|nil result_or_error Данные, nil или сообщение об ошибке (для HTTP-функций)
--- @return any ... Дополнительные результаты
function Logger.with_error(func, ...)
    active_contexts = active_contexts + 1
    context_counter = context_counter + 1
    local context_id = context_counter -- Используем число для предотвращения аллокаций строк

    local prev_context_id = current_context_id
    if prev_context_id then
        table_insert(context_stack, prev_context_id)
    end
    current_context_id = context_id

    local results = { pcall(func, ...) }

    -- Восстанавливаем контекст (защита от повреждения стека)
    current_context_id = prev_context_id
    if prev_context_id then
        table_remove(context_stack)
    end

    local function cleanup()
        last_errors[context_id] = nil
        active_contexts = active_contexts - 1
        if active_contexts == 0 then
            context_counter = 0
        end
    end

    local ok = results[1]
    if not ok then
        -- Ошибка выполнения (crash)
        local err = results[2]
        Logger.error("Logger", "Ошибка выполнения: %s", tostring(err))
        cleanup()
        return false, tostring(err)
    end

    -- Успешное выполнение функции, проверяем результат
    local success = results[2]
    if not success then
        -- Извлекаем ошибку, которая была сохранена для ЭТОГО контекста
        local err = last_errors[context_id] or "Неизвестная ошибка"
        cleanup()
        return false, err
    end

    -- Успех
    cleanup()
    return unpack(results, 2)
end

-- Регистрация пулов при загрузке модуля
local tp = ModuleManager.get_module("table_pool")
if tp then
    -- Пул для записей в буфере и очереди
    tp.register_type("log_entry", { "timestamp", "level", "message", "context_id" })
    -- Пул для временных объектов при JSON-логировании
    tp.register_type("log_data", { "timestamp", "level", "component", "message", "context_id" })
end

-- Первичная инициализация кэша
Logger.refresh_log_level()

return Logger
