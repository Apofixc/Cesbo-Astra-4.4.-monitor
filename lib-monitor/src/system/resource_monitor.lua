--- @class ResourceMonitor
local ResourceMonitor = {}

-- 1. Стандартные Lua функции
local os_time = os.time
local pcall = pcall
local tostring = tostring
local io_open = io.open

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ResourceMonitor"
local UPDATE_INTERVAL = 5 -- секунд

-- Внутреннее состояние
ResourceMonitor._report = {}
ResourceMonitor._json_cache = nil
ResourceMonitor._last_update = 0
ResourceMonitor._pid = nil

--- Инициализация монитора ресурсов
function ResourceMonitor.init()
    -- Получаем PID процесса Astra
    local f = io_open("/proc/self/stat", "r")
    if f then
        local content = f:read("*a")
        f:close()
        ResourceMonitor._pid = content:match("^(%d+)")
    end
    
    ResourceMonitor.check()
    Logger.info(COMPONENT_NAME, "Resource monitor initialized (PID: %s)", tostring(ResourceMonitor._pid))
end

--- Собирает актуальные метрики системы
function ResourceMonitor.check()
    local now = os_time()
    if now - ResourceMonitor._last_update < UPDATE_INTERVAL and ResourceMonitor._json_cache then
        return
    end

    local report = {
        type = "sys",
        pid = tonumber(ResourceMonitor._pid),
        timestamp = now,
        cpu = {
            total = 0, -- В реальной Astra здесь будет вызов системных утилит
            threads = 0
        },
        memory = {
            lua_kb = collectgarbage("count"),
            rss_kb = 0
        },
        system = {
            load_avg = {0, 0, 0}
        }
    }

    -- Попытка получить реальные данные из /proc (упрощенно)
    local f = io_open("/proc/loadavg", "r")
    if f then
        local line = f:read("*l")
        f:close()
        if line then
            local l1, l5, l15 = line:match("([^%s]+)%s+([^%s]+)%s+([^%s]+)")
            report.system.load_avg = {tonumber(l1), tonumber(l5), tonumber(l15)}
        end
    end

    ResourceMonitor._report = report
    ResourceMonitor._last_update = now
    
    -- Кэшируем JSON для HTTP сервера
    local ok, json = pcall(json_encode, report)
    if ok then
        ResourceMonitor._json_cache = json
    end
end

--- Возвращает последний отчет
--- @return table Таблица с метриками
function ResourceMonitor.get_report()
    ResourceMonitor.check()
    return ResourceMonitor._report
end

--- Возвращает кэшированный JSON отчет
--- @return string|nil JSON строка
function ResourceMonitor.get_json_report()
    ResourceMonitor.check()
    return ResourceMonitor._json_cache
end

--- Проверяет, запущен ли монитор (всегда true, если модуль загружен)
--- @return boolean
function ResourceMonitor.is_running()
    return true
end

-- Автоматическая инициализация при загрузке
ResourceMonitor.init()

return ResourceMonitor
