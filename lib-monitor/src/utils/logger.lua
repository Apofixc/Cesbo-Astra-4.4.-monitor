-- ===========================================================================
-- Модуль `utils.logger`
--
-- Высокопроизводительный модуль логирования с поддержкой контекстов ошибок,
-- пакетной записи и кольцевого буфера для диагностики.
-- ===========================================================================

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
local TablePool = nil -- Кэшируется при первом обращении

-- 3. Глобальные зависимости Astra
local log = ModuleManager.get_global_dependency("log")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации

--- Локальная конфигурация модуля (значения по умолчанию)
local _m_config = {
    LogLevel = "INFO",
    LogFormat = "TEXT",
    LogBatchEnabled = false,
    LogBufferSize = 0,
    MaxLogQueueSize = 200,
    MaxLogComponents = 100,
}

local LOG_LEVELS = {
    DEBUG = 1,
    INFO = 2,
    WARN = 3,
    ERROR = 4,
    NONE = 5
}

local LEVEL_MAP = {
    DEBUG = "debug",
    INFO = "info",
    WARN = "warning",
    ERROR = "error"
}

-- 5. Внутреннее состояние (Private State)

--- @class LoggerState
--- @field last_errors table<number, string> Контекстное хранение ошибок
--- @field context_stack number[] Стек контекстов
--- @field current_context_id number|nil Текущий ID контекста
--- @field context_counter number Счетчик контекстов
--- @field active_contexts number Количество активных контекстов
--- @field component_list string[] Список компонентов в буфере
--- @field context_buffer table<string, table[]> Буфер логов по компонентам
--- @field buffer_size number Размер буфера
--- @field log_queue table[] Очередь пакетной записи
--- @field cached_log_level number Кэшированный уровень лога
--- @field cached_log_format string Кэшированный формат лога
--- @field cached_log_buffer_size number Кэшированный размер буфера
--- @field cached_log_batch_enabled boolean Флаг пакетной записи
--- @field last_config_refresh number Время последнего обновления конфига

local state = {
    -- Контекстное хранение ошибок
    last_errors = {},
    context_stack = {},
    current_context_id = nil,
    context_counter = 0,
    active_contexts = 0,

    -- Диагностический буфер
    component_list = {},
    context_buffer = {},
    buffer_size = 1000,

    -- Очередь пакетной записи
    log_queue = {},

    -- Кэш конфигурации
    cached_log_level = nil,
    cached_log_format = nil,
    cached_log_buffer_size = 0,
    cached_log_batch_enabled = false,
    last_config_refresh = 0
}

-- ===========================================================================
-- Внутренние функции (Private/Protected)
-- ===========================================================================

--- Возвращает модуль TablePool (ленивая загрузка)
--- @return TablePool|nil
local function _get_table_pool()
    if TablePool then return TablePool end
    TablePool = ModuleManager.get_module("table_pool")

    -- Пул для записей в буфере и очереди
    TablePool.register_type("log_entry", { "timestamp", "level", "message", "context_id" })
    -- Пул для временных объектов при JSON-логировании
    TablePool.register_type("log_data", { "timestamp", "level", "component", "message", "context_id" })

    return TablePool
end

--- Обновляет кэшированные параметры логирования из локальной конфигурации
local function _refresh_config_cache()
    state.cached_log_level = LOG_LEVELS[_m_config.LogLevel] or LOG_LEVELS.INFO
    state.cached_log_format = _m_config.LogFormat or "TEXT"
    state.cached_log_buffer_size = _m_config.LogBufferSize or 0
    state.cached_log_batch_enabled = _m_config.LogBatchEnabled or false
end

--- Возвращает текущий уровень логирования
--- @return number
local function _get_current_level()
    if not state.cached_log_level then
        _refresh_config_cache()
    end
    return state.cached_log_level
end

--- Проверяет, должен ли лог данного уровня быть записан
--- @param level number Числовой уровень лога
--- @return boolean
local function _should_log(level)
    return level >= _get_current_level()
end

--- Формирует текстовое сообщение лога с защитой от ошибок форматирования
--- @param format_str any
--- @param ... any
--- @return string
local function _format_message(format_str, ...)
    local str = tostring(format_str)
    if select("#", ...) > 0 then
        local ok, res = pcall(string_format, str, ...)
        if ok then return res end
        return str .. " [ОШИБКА ФОРМАТИРОВАНИЯ]"
    end
    return str
end

--- Сохраняет ошибку в текущем контексте (Lazy Propagation)
--- @param msg string Текст ошибки
local function _propagate_error(msg)
    if not state.current_context_id then return end
    -- Записываем только в текущий контекст (O(1))
    state.last_errors[state.current_context_id] = msg
end

--- Выполняет непосредственную запись сообщения в лог Astra или консоль
--- @param level_name string Имя уровня логирования
--- @param message string Текст сообщения
local function _write_to_output(level_name, message)
    local method_name = LEVEL_MAP[level_name] or level_name:lower()
    if log and type(log) == "table" and type(log[method_name]) == "function" then
        local ok, err = pcall(log[method_name], message)
        if not ok then
            print(string_format("[ОШИБКА ЛОГГЕРА] Не удалось записать в лог Astra: %s", tostring(err)))
        end
    else
        print(string_format("[%s] %s", level_name, message))
    end
end

--- Добавляет сообщение в очередь пакетной записи
--- @param level_name string Имя уровня логирования
--- @param message string Текст сообщения
local function _enqueue_log(level_name, message)
    if not state.cached_log_batch_enabled then
        _write_to_output(level_name, message)
        return
    end

    local pool = _get_table_pool()
    local item = pool and pool.get("log_entry") or {}
    item.level = level_name
    item.message = message

    if #state.log_queue < _m_config.MaxLogQueueSize then
        table_insert(state.log_queue, item)
    else
        -- Если очередь переполнена, сбрасываем немедленно
        -- Используем прямую очистку очереди, так как Logger еще не полностью определен
        local current_queue = state.log_queue
        state.log_queue = {}
        for _, q_item in ipairs(current_queue) do
            _write_to_output(q_item.level, q_item.message)
            if pool then pool.release(q_item, "log_entry") end
        end
        table_insert(state.log_queue, item)
    end
end

--- Добавляет запись в кольцевой буфер логов
--- @param level string Уровень лога
--- @param component string Имя компонента
--- @param message string Текст сообщения
--- @param context_id? number ID контекста
--- @param now? number Текущее время
local function _write_to_buffer(level, component, message, context_id, now)
    if not state.context_buffer[component] then
        -- Ограничение количества отслеживаемых компонентов
        if #state.component_list >= _m_config.MaxLogComponents then
            local old_comp = table_remove(state.component_list, 1)
            -- Вызываем очистку напрямую
            local old_buffer = state.context_buffer[old_comp]
            if old_buffer then
                local pool = _get_table_pool()
                for i = 1, #old_buffer do
                    if pool and old_buffer[i] then pool.release(old_buffer[i], "log_entry") end
                end
                state.context_buffer[old_comp] = nil
            end
        end
        table_insert(state.component_list, component)
        state.context_buffer[component] = {}
    end

    local buffer = state.context_buffer[component]
    local pool = _get_table_pool()
    local entry = pool and pool.get("log_entry") or {}

    entry.timestamp = now or os_time()
    entry.level = level
    entry.message = message
    entry.context_id = context_id

    table_insert(buffer, entry)

    -- Ограничение размера буфера (FIFO)
    if #buffer > state.buffer_size then
        local old = table_remove(buffer, 1)
        if pool and old then
            pool.release(old, "log_entry")
        end
    end
end

--- Внутренняя функция для записи лога
--- @param level_name string Имя уровня (INFO, ERROR и т.д.)
--- @param component string Имя компонента
--- @param format_str any Форматная строка
--- @param ... any Аргументы формата
local function _write_log(level_name, component, format_str, ...)
    local level = LOG_LEVELS[level_name]
    local is_error = (level_name == "ERROR")
    local should_log_msg = _should_log(level)

    -- Оптимизация: Проверяем уровень ДО формирования строки
    if not should_log_msg and not (is_error and state.current_context_id) then
        return
    end

    local msg = _format_message(format_str, ...)

    -- Сохранение ошибки в контекст
    if is_error then
        _propagate_error(msg)
    end

    local now = os_time()

    -- Буферизация для диагностики
    if state.cached_log_buffer_size > 0 then
        state.buffer_size = state.cached_log_buffer_size
        -- Используем прямую запись в буфер, так как Logger еще не полностью определен
        _write_to_buffer(level_name, component, msg, state.current_context_id, now)
    end

    -- Вывод лога
    if should_log_msg then
        local output_msg
        if state.cached_log_format == "JSON" then
            local pool = _get_table_pool()
            local log_data = pool and pool.get("log_data") or {}
            log_data.timestamp = now
            log_data.level = level_name
            log_data.component = component
            log_data.message = msg
            log_data.context_id = state.current_context_id

            output_msg = json_encode(log_data)

            if pool then pool.release(log_data, "log_data") end
        else
            output_msg = string_format("[%s] %s", component, msg)
        end

        _enqueue_log(level_name, output_msg)
    end
end


-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- @class Logger
local Logger = {}

-- Экспорт буфера для внешнего доступа (только для чтения/диагностики)
Logger._context_buffer = state.context_buffer

--- Инициализирует подписку на обновление конфигурации
function Logger.init_config_subscription()
    if _G.EventDispatcher then
        _G.EventDispatcher:subscribe("config:updated:logger", function(new_config)
            for k, v in pairs(new_config) do
                _m_config[k] = v
            end
            _refresh_config_cache()
            Logger.info("Logger", "Конфигурация логирования обновлена")
        end)
    end
end

--- Обновляет кэшированный уровень логирования
--- @deprecated Используйте систему событий
function Logger.refresh_log_level()
    _refresh_config_cache()
end

--- Добавляет запись в кольцевой буфер логов
--- @param level string Уровень лога
--- @param component string Имя компонента
--- @param message string Текст сообщения
--- @param context_id? number ID контекста
--- @param now? number Текущее время
function Logger.buffer_log(level, component, message, context_id, now)
    _write_to_buffer(level, component, message, context_id, now)
end

--- Полностью очищает буфер логов для указанного компонента
--- @param component string Имя компонента
function Logger.clear_component_buffer(component)
    local buffer = state.context_buffer[component]
    if not buffer then return end

    local pool = _get_table_pool()
    for i = 1, #buffer do
        local entry = buffer[i]
        if pool and entry then
            pool.release(entry, "log_entry")
        end
        buffer[i] = nil
    end
    state.context_buffer[component] = nil

    -- Удаляем из списка компонентов
    for i = 1, #state.component_list do
        if state.component_list[i] == component then
            table_remove(state.component_list, i)
            break
        end
    end
end

--- Возвращает содержимое буфера логов
--- @param component string Имя компонента
--- @param limit? number Лимит записей
--- @return table Список записей
function Logger.get_buffer(component, limit)
    local buffer = state.context_buffer[component]
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
    if #state.log_queue == 0 then return end

    local current_queue = state.log_queue
    state.log_queue = {}

    local pool = _get_table_pool()
    for _, item in ipairs(current_queue) do
        _write_to_output(item.level, item.message)
        if pool then
            pool.release(item, "log_entry")
        end
    end
end

--- Логирует сообщение с уровнем INFO
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.info(component, format_str, ...)
    _write_log("INFO", type(component) == "string" and component or tostring(component), format_str, ...)
end

--- Логирует сообщение с уровнем ERROR и сохраняет в контекст, если он активен
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.error(component, format_str, ...)
    _write_log("ERROR", type(component) == "string" and component or tostring(component), format_str, ...)
end

--- Логирует сообщение с уровнем DEBUG
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.debug(component, format_str, ...)
    _write_log("DEBUG", type(component) == "string" and component or tostring(component), format_str, ...)
end

--- Логирует сообщение с уровнем WARN
--- @param component string Имя компонента
--- @param format_str string Форматная строка
--- @param ... any Аргументы для формата
function Logger.warning(component, format_str, ...)
    _write_log("WARN", type(component) == "string" and component or tostring(component), format_str, ...)
end

--- Выполняет функцию в контексте отслеживания ошибок
--- @param func function Функция для выполнения
--- @param ... any Аргументы функции
--- @return boolean Статус выполнения
--- @return any|string|nil Данные, nil или сообщение об ошибке
--- @return any ... Дополнительные результаты
function Logger.with_error(func, ...)
    state.active_contexts = state.active_contexts + 1
    state.context_counter = state.context_counter + 1
    local context_id = state.context_counter

    -- Push context
    local prev_context_id = state.current_context_id
    if prev_context_id then
        table_insert(state.context_stack, prev_context_id)
    end
    state.current_context_id = context_id

    -- Execute function
    local results = { pcall(func, ...) }

    -- Lazy Propagation: пробрасываем ошибку вверх при завершении контекста
    local current_err = state.last_errors[context_id]
    if current_err and prev_context_id then
        state.last_errors[prev_context_id] = current_err
    end

    -- Pop context (защита от повреждения стека)
    state.current_context_id = prev_context_id
    if prev_context_id then
        table_remove(state.context_stack)
    end

    -- Вспомогательная функция очистки
    local function _cleanup()
        state.last_errors[context_id] = nil
        state.active_contexts = state.active_contexts - 1
        if state.active_contexts == 0 then
            state.context_counter = 0
        end
    end

    local ok = results[1]
    if not ok then
        -- Ошибка выполнения (crash)
        local err = results[2]
        Logger.error("Logger", "Ошибка выполнения: %s", tostring(err))
        _cleanup()
        return false, tostring(err)
    end

    -- Успешное выполнение функции, проверяем бизнес-результат
    local success = results[2]
    if not success then
        -- Извлекаем ошибку, которая была сохранена для ЭТОГО контекста
        local err = state.last_errors[context_id] or "Неизвестная ошибка"
        _cleanup()
        return false, err
    end

    -- Успех
    _cleanup()
    return unpack(results, 2)
end

-- ===========================================================================
-- Инициализация модуля
-- ===========================================================================


-- Первичная инициализация кэша
_refresh_config_cache()

return Logger
