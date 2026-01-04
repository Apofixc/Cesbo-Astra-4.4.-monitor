-- ===========================================================================
-- Модуль `resource_monitor`
--
-- Отвечает за мониторинг системных ресурсов процесса Astra и всей системы.
-- Поддерживает Pull-модель получения данных и управление состоянием.
-- ===========================================================================

-- 1. Стандартные Lua функции
local collectgarbage = collectgarbage
local io = io
local os = os
local tonumber = tonumber
local ipairs = ipairs
local pairs = pairs
local type = type
local string_match = string.match
local string_gmatch = string.gmatch

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local timer = ModuleManager.get_global_dependency("timer")
local astra_utils = ModuleManager.get_global_dependency("utils")
local json_encode = ModuleManager.get_global_dependency("json.encode")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ResourceMonitor"
local UPDATE_INTERVAL = 1 -- секунда для точного расчета CPU
local FD_UPDATE_INTERVAL = 10 -- дескрипторы проверяем реже (дорого)
local USER_HZ = 100 -- Стандарт для Linux

-- 5. Инициализация объекта
--- @class ResourceMonitor
--- @field private _timer table|nil Таймер фонового обновления
--- @field private _pid number|nil Кэшированный PID процесса
--- @field private _last_stats table Данные предыдущего замера для расчета дельт
--- @field private _current_report table|nil Последний сформированный отчет
--- @field private _fd_counter number Счетчик для интервала проверки дескрипторов
--- @field private _last_fd_count number Последнее значение количества дескрипторов
--- @field private _missing_files table|nil Кэш отсутствующих файлов для предотвращения спама в логах
--- @field private _json_cache string|nil Кэш последнего отчета в формате JSON
local ResourceMonitor = {
    _timer = nil,
    _pid = nil,
    _current_report = nil,
    _json_cache = nil,
    _fd_counter = 0,
    _last_fd_count = 0,
    _last_stats = {
        utime = 0,
        stime = 0,
        time = 0,
        read_bytes = 0,
        write_bytes = 0,
        net = {} -- [iface] = { rx, tx }
    }
}

-- ===========================================================================
-- Вспомогательные функции (Парсеры)
-- ===========================================================================

--- Читает содержимое файла
--- @param path string Путь к файлу
--- @return string|nil Содержимое файла
local function read_file(path)
    local f = io.open(path, "r")
    if not f then
        -- Логируем только один раз для каждого пути, чтобы не спамить
        if not ResourceMonitor._missing_files then ResourceMonitor._missing_files = {} end
        if not ResourceMonitor._missing_files[path] then
            Logger.warn(COMPONENT_NAME, "File not found or not readable: %s", path)
            ResourceMonitor._missing_files[path] = true
        end
        return nil
    end
    local content = f:read("*all")
    f:close()
    return content
end

--- Извлекает PID процесса (вызывается один раз)
--- @return number|nil
local function get_self_pid()
    local content = read_file("/proc/self/stat")
    if not content then return nil end
    return tonumber(string_match(content, "^(%d+)"))
end

--- Извлекает статистику из /proc/self/stat
--- @return table|nil { utime, stime, threads, rss_pages }
local function parse_proc_stat()
    local content = read_file("/proc/self/stat")
    if not content then return nil end

    -- Имя процесса может содержать пробелы и скобки, например (astra main)
    -- Поэтому ищем последнюю закрывающую скобку и парсим от неё
    local rest = string_match(content, "^%d+%s+%b()%s+(.+)$")
    if not rest then return nil end

    -- Оптимизация: извлекаем нужные поля одним паттерном
    -- Поля после имени процесса:
    -- 1:state, 2:ppid, 3:pgrp, 4:session, 5:tty_nr, 6:tpgid, 7:flags, 8:minflt, 9:cminflt, 10:majflt, 11:cmajflt,
    -- 12:utime, 13:stime, 14:cutime, 15:cstime, 16:priority, 17:nice, 18:num_threads, 19:itrealvalue, 20:starttime,
    -- 21:vsize, 22:rss
    local utime, stime, threads, rss_pages = string_match(rest, 
        "^%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+%S+%s+(%d+)%s+(%d+)%s+%S+%s+%S+%s+%S+%s+%S+%s+(%d+)%s+%S+%s+%S+%s+%S+%s+(%d+)")

    if not utime then return nil end

    return {
        utime = tonumber(utime),
        stime = tonumber(stime),
        threads = tonumber(threads),
        rss_pages = tonumber(rss_pages)
    }
end

--- Читает расширенный статус из /proc/self/status
--- @return table|nil { VmSize, VmRSS, VmShared, voluntary_ctxt, nonvoluntary_ctxt }
local function parse_proc_status()
    local content = read_file("/proc/self/status")
    if not content then return nil end

    local res = {}
    for line in string_gmatch(content, "[^\r\n]+") do
        local key, val = string_match(line, "^(%w+):\t%s*(.+)$")
        if key and val then
            if key == "VmSize" or key == "VmRSS" or key == "VmShared" then
                res[key] = tonumber(string_match(val, "%d+"))
            elseif key == "voluntary_ctxt_switches" or key == "nonvoluntary_ctxt_switches" then
                res[key] = tonumber(val)
            end
        end
    end
    return res
end

--- Читает статистику I/O из /proc/self/io
--- @return table|nil { read_bytes, write_bytes }
local function parse_proc_io()
    local content = read_file("/proc/self/io")
    if not content then return nil end

    local res = {}
    for line in string_gmatch(content, "[^\r\n]+") do
        local key, val = string_match(line, "^(%w+):%s*(%d+)$")
        if key and val then
            res[key] = tonumber(val)
        end
    end
    return res
end

--- Читает статистику сети из /proc/net/dev
--- @return table|nil { [iface] = { rx_bytes, tx_bytes, rx_errs, tx_errs, rx_drop, tx_drop } }
local function parse_net_dev()
    local content = read_file("/proc/net/dev")
    if not content then return nil end

    local res = {}
    for line in string_gmatch(content, "[^\r\n]+") do
        local iface, data_part = string_match(line, "^%s*([^%s:]+):%s*(.*)$")
        if iface and data_part then
            local parts = {}
            for val in string_gmatch(data_part, "%d+") do
                parts[#parts + 1] = tonumber(val)
            end
            if #parts >= 16 then
                res[iface] = {
                    rx_bytes = parts[1],
                    rx_errs = parts[3],
                    rx_drop = parts[4],
                    tx_bytes = parts[9],
                    tx_errs = parts[11],
                    tx_drop = parts[12]
                }
            end
        end
    end
    return res
end

--- Читает температуру CPU
--- @return number|nil Температура в градусах Цельсия
local function parse_cpu_temp()
    -- Пробуем стандартные зоны thermal_zone0, thermal_zone1
    for i = 0, 1 do
        local path = "/sys/class/thermal/thermal_zone" .. i .. "/temp"
        local content = read_file(path)
        if content then
            local temp = tonumber(content)
            if temp then return temp / 1000 end
        end
    end
    return nil
end

--- Получает Load Average системы
--- @return table|nil { l1, l5, l15 }
local function parse_load_avg()
    local content = read_file("/proc/loadavg")
    if not content then return nil end
    local l1, l5, l15 = string_match(content, "([^%s]+)%s+([^%s]+)%s+([^%s]+)")
    return { tonumber(l1), tonumber(l5), tonumber(l15) }
end

--- Считает количество открытых файловых дескрипторов.
--- Использует чтение директории /proc/self/fd.
--- @return number
local function get_fd_count()
    -- 1. Оптимизация: используем встроенную функцию Astra если доступна
    if astra_utils and astra_utils.fd_count then
        return astra_utils.fd_count()
    end

    -- 2. Попытка прочитать из /proc/self/status (поле FDSize)
    -- Хотя FDSize - это размер таблицы дескрипторов, а не точное количество занятых,
    -- это дает верхнюю границу без вызова внешних процессов.
    -- Но для точности в Astra лучше использовать popen только если нет альтернатив.
    
    -- 3. Fallback: использование popen (дорого, поэтому вызывается редко через FD_UPDATE_INTERVAL)
    local count = 0
    local p = io.popen("ls -1 /proc/self/fd 2>/dev/null | wc -l")
    if p then
        local res = p:read("*l")
        count = tonumber(res) or 0
        p:close()
    end
    return count
end

-- ===========================================================================
-- Основная логика сбора данных
-- ===========================================================================

--- Выполняет один цикл сбора данных и расчета метрик.
--- Может вызываться вручную для немедленного обновления данных.
function ResourceMonitor.check()
    local stat = parse_proc_stat()
    local status = parse_proc_status()
    local io_stats = parse_proc_io()
    local net_stats = parse_net_dev()
    local load_avg = parse_load_avg()
    local temp = parse_cpu_temp()
    
    if not stat then return end

    -- Кэшируем PID при первом нахождении
    if not ResourceMonitor._pid then
        ResourceMonitor._pid = get_self_pid()
        -- Если PID найден, можно считать, что /proc/self/stat доступен
        -- и не логировать отсутствие файлов для него в будущем
    end

    local current_time = os.time()
    local cpu = { total = 0, user = 0, sys = 0 }
    local io_speed = { read_bps = 0, write_bps = 0 }
    local net_report = {}

    local delta_time = (ResourceMonitor._last_stats.time > 0) and (current_time - ResourceMonitor._last_stats.time) or 0

    if delta_time > 0 then
        -- Расчет CPU
        local delta_utime = stat.utime - ResourceMonitor._last_stats.utime
        local delta_stime = stat.stime - ResourceMonitor._last_stats.stime
        cpu.user = (delta_utime / USER_HZ) / delta_time * 100
        cpu.sys = (delta_stime / USER_HZ) / delta_time * 100
        cpu.total = cpu.user + cpu.sys

        -- Расчет I/O Speed
        if io_stats and ResourceMonitor._last_stats.read_bytes then
            local delta_read = io_stats.read_bytes - ResourceMonitor._last_stats.read_bytes
            local delta_write = io_stats.write_bytes - ResourceMonitor._last_stats.write_bytes
            
            -- Обработка сброса счетчиков (wrap-around)
            if delta_read < 0 then delta_read = 0 end
            if delta_write < 0 then delta_write = 0 end

            io_speed.read_bps = delta_read / delta_time
            io_speed.write_bps = delta_write / delta_time
        end

        -- Расчет Network Speed
        if net_stats then
            for iface, data in pairs(net_stats) do
                local last = ResourceMonitor._last_stats.net[iface]
                if last then
                    local delta_rx = data.rx_bytes - last.rx_bytes
                    local delta_tx = data.tx_bytes - last.tx_bytes

                    -- Обработка сброса счетчиков (wrap-around)
                    if delta_rx < 0 then delta_rx = 0 end
                    if delta_tx < 0 then delta_tx = 0 end

                    local iface_report = net_report[iface]
                    if not iface_report then
                        iface_report = {}
                        net_report[iface] = iface_report
                    end
                    
                    iface_report.rx_bps = delta_rx / delta_time
                    iface_report.tx_bps = delta_tx / delta_time
                    iface_report.rx_errs = data.rx_errs
                    iface_report.tx_errs = data.tx_errs
                    iface_report.rx_drop = data.rx_drop
                    iface_report.tx_drop = data.tx_drop
                end
            end
        end

        -- Обновляем состояние для следующего замера только если delta_time > 0
        ResourceMonitor._last_stats.utime = stat.utime
        ResourceMonitor._last_stats.stime = stat.stime
        ResourceMonitor._last_stats.time = current_time
        if io_stats then
            ResourceMonitor._last_stats.read_bytes = io_stats.read_bytes
            ResourceMonitor._last_stats.write_bytes = io_stats.write_bytes
        end
        if net_stats then
            -- Обновляем кэш интерфейсов без пересоздания таблиц где возможно
            local net_cache = ResourceMonitor._last_stats.net
            -- Удаляем интерфейсы, которых больше нет
            for iface in pairs(net_cache) do
                if not net_stats[iface] then net_cache[iface] = nil end
            end
            -- Обновляем существующие или добавляем новые
            for iface, data in pairs(net_stats) do
                local cache_item = net_cache[iface]
                if not cache_item then
                    cache_item = {}
                    net_cache[iface] = cache_item
                end
                cache_item.rx_bytes = data.rx_bytes
                cache_item.tx_bytes = data.tx_bytes
            end
        end
    end

    -- Обновление счетчика дескрипторов (реже)
    if ResourceMonitor._fd_counter <= 0 then
        ResourceMonitor._last_fd_count = get_fd_count()
        ResourceMonitor._fd_counter = FD_UPDATE_INTERVAL
    else
        ResourceMonitor._fd_counter = ResourceMonitor._fd_counter - 1
    end

    -- Формируем итоговый отчет
    ResourceMonitor._current_report = {
        type = "sys",
        pid = ResourceMonitor._pid,
        timestamp = current_time,
        cpu = {
            total = cpu.total,
            user = cpu.user,
            sys = cpu.sys,
            threads = stat.threads,
            temp_c = temp,
            ctxt_switches = status and ((status.voluntary_ctxt_switches or 0) + (status.nonvoluntary_ctxt_switches or 0)) or 0
        },
        memory = {
            lua_kb = collectgarbage("count"),
            rss_kb = status and status.VmRSS or (stat.rss_pages * 4),
            vms_kb = status and status.VmSize or 0,
            shared_kb = status and status.VmShared or 0
        },
        io = io_speed,
        network = net_report,
        system = {
            load_avg = load_avg,
            fd_count = ResourceMonitor._last_fd_count
        }
    }

    Logger.debug(COMPONENT_NAME, "Update: CPU: %.1f%%, RSS: %d KB, FDs: %d", 
        cpu.total, ResourceMonitor._current_report.memory.rss_kb, ResourceMonitor._current_report.system.fd_count)

    -- Обновляем кэш JSON
    if json_encode then
        local ok, res = pcall(json_encode, { status = "ok", resources = ResourceMonitor._current_report, timestamp = os.time() })
        if ok then
            ResourceMonitor._json_cache = res
        end
    end
end

-- ===========================================================================
-- Публичный API
-- ===========================================================================

--- Запускает фоновый мониторинг ресурсов
--- @return boolean Статус выполнения
function ResourceMonitor.start()
    if ResourceMonitor._timer then
        Logger.debug(COMPONENT_NAME, "Monitor already running")
        return true
    end

    -- Первый замер для инициализации дельт
    ResourceMonitor.check()

    ResourceMonitor._timer = timer({
        interval = UPDATE_INTERVAL,
        callback = function()
            ResourceMonitor.check()
        end
    })

    Logger.info(COMPONENT_NAME, "ResourceMonitor started (interval: %d s)", UPDATE_INTERVAL)
    return true
end

--- Останавливает фоновый мониторинг
function ResourceMonitor.stop()
    if ResourceMonitor._timer then
        ResourceMonitor._timer:close()
        ResourceMonitor._timer = nil
        Logger.info(COMPONENT_NAME, "ResourceMonitor stopped")
    end
    return true
end

--- Проверяет, запущен ли мониторинг
--- @return boolean
function ResourceMonitor.is_running()
    return ResourceMonitor._timer ~= nil
end

--- Возвращает отчет о ресурсах (Pull-модель).
--- @param filter table|string|nil Список категорий для возврата (например, {"cpu", "memory"})
--- @return table|nil Отчет о ресурсах
function ResourceMonitor.get_report(filter)
    if not ResourceMonitor._current_report then return nil end
    
    if not filter then
        return ResourceMonitor._current_report
    end

    local report = {}
    -- Всегда включаем базовые поля
    report.type = ResourceMonitor._current_report.type
    report.pid = ResourceMonitor._current_report.pid
    report.timestamp = ResourceMonitor._current_report.timestamp

    if type(filter) == "string" then
        -- Поддержка строки через запятую "cpu,memory"
        local f = filter
        filter = {}
        for cat in string_gmatch(f, "[^,]+") do
            filter[#filter + 1] = cat
        end
    end

    if type(filter) == "table" then
        for _, cat in ipairs(filter) do
            if ResourceMonitor._current_report[cat] then
                report[cat] = ResourceMonitor._current_report[cat]
            end
        end
    end

    return report
end

--- Возвращает кэш последнего отчета в формате JSON
--- @return string|nil
function ResourceMonitor.get_json_cache()
    return ResourceMonitor._json_cache
end

return ResourceMonitor
