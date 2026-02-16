-- ===========================================================================
-- LIB-MONITOR: ЭТАЛОННЫЙ СКРИПТ ЗАПУСКА
--
-- Данный файл является точкой входа для системы мониторинга.
-- Он подключает библиотеку через init_monitor и запускает HTTP-сервер.
-- ===========================================================================

-- 1. Настройка путей поиска модулей
local script_path = debug.getinfo(1).source:match("@?(.*/)") or "./"
package.path = script_path .. "?.lua;" .. package.path

-- 2. Подключение библиотеки
-- init_monitor автоматически проверит зависимости и загрузит все модули
-- Опционально: require("init_monitor")(name_pid, debug, filename, syslog, stdout)
require("init_monitor")()

-- 3. Запуск HTTP сервера
-- Параметры берутся из переменных окружения или используются значения по умолчанию
local bind_addr = os.getenv("MONITOR_BIND_ADDR") or "0.0.0.0"
local bind_port = tonumber(os.getenv("MONITOR_BIND_PORT")) or 8080

-- server_start экспортирована в _G модулем init_monitor
if _G.server_start then
    _G.server_start(bind_addr, bind_port)
end

print("[INFO] Система мониторинга lib-monitor успешно запущена")
