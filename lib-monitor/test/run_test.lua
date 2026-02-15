-- run_test.lua
-- Скрипт для запуска тестов и сбора метрик покрытия с Luacov

--- @class TestRunner
--- @brief Утилита для запуска тестов и сбора метрик покрытия с Luacov.
local TestRunner = {}

-- 1. Константы и конфигурация
local function _detect_lib_dir()
    local info = debug.getinfo(1, "S")
    local source = info and info.source
    if source and source:sub(1, 1) == "@" then
        local script_path = source:sub(2)
        local test_dir = script_path:match("^(.+)/")  -- .../lib-monitor/test
        if test_dir then
            local lib_dir = test_dir:match("^(.+)/")  -- .../lib-monitor
            if lib_dir then return lib_dir end
        end
    end
    return "/opt/Cesbo-Astra-4.4.-monitor/lib-monitor"
end
local LIB_DIR = _detect_lib_dir()
local TEST_ROOT_DIR = LIB_DIR .. "/test"
local LUAC_REPORT_PATH = LIB_DIR .. "/test/luacov.report.out"
local LUAC_CONFIG_PATH = LIB_DIR .. "/test/.luacov"

-- 2. Вспомогательные функции
--- @brief Экранирует строку для использования в командах shell.
--- @param s string Исходная строка.
--- @return string Экранированная строка.
local function shell_escape(s)
    return "'" .. string.gsub(s, "'", "'\\''") .. "'"
end

--- @brief Настраивает среду выполнения, включая пути Lua и инициализацию Luacov.
--- @return boolean Успешна ли инициализация Luacov.
function TestRunner.setup_environment()
    -- Настройка package.path: тесты + lib-monitor src для require
    package.path = string.format(
        "%s/?.lua;%s/luacov/?.lua;%s/?.lua;%s/unit/?.lua;%s/integration/?.lua;%s/system/?.lua;%s/performance/?.lua;%s/stress/?.lua;%s/tools/?.lua;%s",
        LIB_DIR, TEST_ROOT_DIR, TEST_ROOT_DIR, TEST_ROOT_DIR, TEST_ROOT_DIR, TEST_ROOT_DIR, TEST_ROOT_DIR, TEST_ROOT_DIR, TEST_ROOT_DIR, package.path
    )

    local ok_lc, luacov_runner = pcall(require, "luacov.runner")
    if ok_lc then
        luacov_runner.init(LUAC_CONFIG_PATH)
        _G.luacov_active = true -- Глобальный флаг для Luacov
        print("Luacov инициализирован.")
    else
        print("Предупреждение: Luacov не загружен. Покрытие кода не будет собираться.")
        _G.luacov_active = false
    end
    return _G.luacov_active
end

--- @brief Рекурсивно ищет тестовые файлы в указанных путях.
--- Тестовые файлы должны иметь префикс "test_" и расширение ".lua".
--- Исключает директории "luacov" и "tools".
--- @param paths table Список относительных путей (файлов или директорий) от TEST_ROOT_DIR для сканирования.
--- @return table Список найденных тестовых файлов (полные пути).
function TestRunner.find_test_files(paths)
    local tests = {}
    local processed_paths = {} -- Для отслеживания уже добавленных файлов

    --- @brief Добавляет файл в список тестов, если он еще не был добавлен.
    --- @param file_path string Полный путь к тестовому файлу.
    local function add_test_file(file_path)
        if not processed_paths[file_path] then
            table.insert(tests, file_path)
            processed_paths[file_path] = true
        end
    end

    --- @brief Рекурсивно сканирует директорию на наличие тестовых файлов.
    --- @param current_path string Полный путь к текущей директории.
    local function scan_path(current_path)
        local command = "find " .. shell_escape(current_path) .. " -maxdepth 1 -mindepth 1 -print0"
        local p = io.popen(command)
        if not p then
            io.stderr:write(string.format("Ошибка: Не удалось открыть pipe для команды 'find' в пути: %s\n", current_path))
            return
        end

        local output = p:read("*all")
        local status = p:close()
        if status ~= true then
            io.stderr:write(string.format("Ошибка: Команда 'find' завершилась с ошибкой в пути: %s\n", current_path))
            return
        end

        for file_or_dir_name in string.gmatch(output, "([^\0]*)\0") do
            if file_or_dir_name == "" then break end

            local full_path = file_or_dir_name
            local stat_cmd = "test -d " .. shell_escape(full_path) .. " && echo 1 || echo 0"
            local is_dir_pipe = io.popen(stat_cmd)
            local is_dir = (is_dir_pipe and is_dir_pipe:read("*n") == 1)
            if is_dir_pipe then is_dir_pipe:close() end

            if is_dir then
                -- Исключаем директории luacov и tools
                if not (string.match(full_path, "/luacov$") or string.match(full_path, "/tools$")) then
                    scan_path(full_path) -- Рекурсивный вызов для поддиректорий
                end
            else
                if string.match(full_path, "%.lua$") and string.match(full_path, "test_") then
                    add_test_file(full_path)
                end
            end
        end
    end

    for _, path_arg in ipairs(paths) do
        local full_path_arg = TEST_ROOT_DIR .. "/" .. path_arg
        local stat_cmd = "test -d " .. shell_escape(full_path_arg) .. " && echo 1 || echo 0"
        local is_dir_pipe = io.popen(stat_cmd)
        local is_dir = (is_dir_pipe and is_dir_pipe:read("*n") == 1)
        if is_dir_pipe then is_dir_pipe:close() end

        if is_dir then
            scan_path(full_path_arg)
        else
            -- Проверяем, является ли аргумент файлом
            local file_stat_cmd = "test -f " .. shell_escape(full_path_arg) .. " && echo 1 || echo 0"
            local is_file_pipe = io.popen(file_stat_cmd)
            local is_file = (is_file_pipe and is_file_pipe:read("*n") == 1)
            if is_file_pipe then is_file_pipe:close() end

            if is_file and string.match(full_path_arg, "%.lua$") and string.match(full_path_arg, "test_") then
                add_test_file(full_path_arg)
            else
                io.stderr:write(string.format("Предупреждение: Аргумент '%s' не является тестовым файлом или директорией.\n", path_arg))
            end
        end
    end

    -- Сортируем тесты для детерминированного порядка
    table.sort(tests)
    return tests
end

--- @brief Запускает список тестовых файлов.
--- Каждый тест выполняется в изолированной среде.
--- @param test_files table Список полных путей к тестовым файлам.
--- @return boolean true, если все тесты пройдены, иначе false.
function TestRunner.execute_tests(test_files)
    local print = print
    local os_clock = os.clock
    local orig_os_clock = _G.os and _G.os.clock

    local total_passed = 0
    local total_failed = 0

    if #test_files == 0 then
        print("Не найдено тестовых файлов для запуска.")
        return true
    end

    for _, file_path in ipairs(test_files) do
        print(string.format("\n--- Запуск теста: %s", file_path))

        local test_env = setmetatable({}, { __index = _G }) -- Изолированная среда для каждого теста
        -- test_helper и test_moc загружаются внутри каждого тестового файла,
        -- поэтому их не нужно явно загружать здесь.

        if orig_os_clock and _G.os then _G.os.clock = orig_os_clock end
        local start_time = os_clock()
        local f, err = loadfile(file_path, "bt", test_env)
        if f then
            local ok, run_err = pcall(f)
            if orig_os_clock and _G.os then _G.os.clock = orig_os_clock end
            local end_time = os_clock()
            local duration = end_time - start_time

            if ok then
                print(string.format("Успех: %s (%.3f сек)", file_path, duration))
                total_passed = total_passed + 1
            else
                print(string.format("Провал: %s (%.3f сек) - %s", file_path, duration, tostring(run_err)))
                total_failed = total_failed + 1
            end
        else
            print(string.format("Ошибка загрузки: %s - %s", file_path, tostring(err)))
            total_failed = total_failed + 1
        end
    end
    print(string.format("\n--- Результаты тестирования: Пройдено: %d, Провалено: %d", total_passed, total_failed))
    return total_failed == 0
end

--- @brief Генерирует и выводит отчет Luacov.
--- Отчет сохраняется в LUAC_REPORT_PATH, а затем его сводка выводится в консоль.
function TestRunner.generate_report()
    if _G.luacov_active then
        local ok_lc_shutdown, luacov_runner = pcall(require, "luacov.runner")
        if ok_lc_shutdown then
            luacov_runner.shutdown()
            print("Статистика покрытия сохранена.")

            local file = io.open(LUAC_REPORT_PATH, "r")
            if file then
                local content = file:read("*all")
                file:close()
                local summary_start = string.find(content, "==============================================================================" .. "\n" .. "Summary")
                if summary_start then
                    local summary_content = string.sub(content, summary_start)
                    print("\n" .. summary_content)
                else
                    print(string.format("\nПредупреждение: Не удалось найти секцию 'Summary' в отчете luacov: %s", LUAC_REPORT_PATH))
                end
            else
                print(string.format("\nОшибка: Не удалось открыть файл отчета luacov: %s", LUAC_REPORT_PATH))
            end
        else
            print("Ошибка: Не удалось завершить работу Luacov.")
        end
    end
end

-- Основная логика выполнения
--- @brief Основная функция для запуска тестового фреймворка.
local function main()
    -- Проверка, что скрипт запущен в среде Astra
    if not _G.astra or type(_G.astra) ~= "table" or not _G.astra.version then
        io.stderr:write("Ошибка: Тесты должны быть запущены в среде Astra (например, с помощью astra4.4.182).\n")
        os.exit(1)
    end

    local luacov_initialized = TestRunner.setup_environment()

    -- Установка глобального флага, указывающего, что тесты запущены через run_test.lua
    _G.RUN_TEST_ACTIVE = true

    print("Начало тестирования Lib-monitor...")
    --- @type table<string> Аргументы командной строки, переданные скрипту.
    local test_paths_to_scan = {}

    if #argv > 1 then
        for key, arg in ipairs(argv) do
            if key > 1 then
                table.insert(test_paths_to_scan, arg)
            end
        end
    else
        -- Если аргументы не указаны, сканируем все поддиректории тестов
        table.insert(test_paths_to_scan, "unit")
        table.insert(test_paths_to_scan, "integration")
        table.insert(test_paths_to_scan, "system")
        table.insert(test_paths_to_scan, "performance")
        table.insert(test_paths_to_scan, "stress")
    end

    local found_tests = TestRunner.find_test_files(test_paths_to_scan)
    local all_tests_passed = TestRunner.execute_tests(found_tests)

    if luacov_initialized then
        TestRunner.generate_report()
    else
        print("Данных для отчета нету.")
    end

    if all_tests_passed then
        os.exit(0)
    else
        os.exit(1)
    end
end

main() -- Запуск основной функции
