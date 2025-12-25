-- ===========================================================================
-- Модуль для проверки доступности всех зависимостей системы мониторинга.
-- ===========================================================================

local Logger = require "src.utils.logger"
local log_info = Logger.info
local log_error = Logger.error

local InitChecker = {}
InitChecker.__index = InitChecker

local COMPONENT_NAME = "InitChecker"

--- Проверяет доступность Lua-модуля.
-- @param string module_name Имя модуля (например, "src.utils.logger").
-- @return boolean true, если модуль доступен; false иначе.
local function check_lua_module(module_name)
    local success, module = pcall(require, module_name)
    if success and module then
        log_info(COMPONENT_NAME, "Lua module '%s' is available.", module_name)
        return true
    else
        log_error(COMPONENT_NAME, "Lua module '%s' is NOT available. Error: %s", module_name, module)
        return false
    end
end

--- Проверяет доступность глобальной функции Astra.
-- @param string func_name Имя глобальной функции (например, "json.encode").
-- @return boolean true, если функция доступна; false иначе.
local function check_global_function(func_name)
    local func_path = {}
    for part in func_name:gmatch("[^%.]+") do
        table.insert(func_path, part)
    end

    local current_scope = _G
    local found = true
    for i, part in ipairs(func_path) do
        if type(current_scope) == "table" and current_scope[part] then
            current_scope = current_scope[part]
        else
            found = false
            break
        end
    end

    if found and type(current_scope) == "function" then
        log_info(COMPONENT_NAME, "Global function '%s' is available.", func_name)
        return true
    elseif found and type(current_scope) == "table" and func_name == "astra.version" then -- Специальная обработка для astra.version
        log_info(COMPONENT_NAME, "Global variable '%s' is available.", func_name)
        return true
    else
        log_error(COMPONENT_NAME, "Global function/variable '%s' is NOT available. Type: %s", func_name, type(current_scope))
        return false
    end
end

--- Проверяет доступность внешней системной команды.
-- @param string command_name Имя команды (например, "nproc").
-- @return boolean true, если команда доступна; false иначе.
local function check_system_command(command_name)
    local f = io.popen("which " .. command_name .. " 2>/dev/null", "r")
    if f then
        local result = f:read("*l")
        f:close()
        if result and result ~= "" then
            log_info(COMPONENT_NAME, "System command '%s' is available at: %s", command_name, result)
            return true
        end
    end
    log_error(COMPONENT_NAME, "System command '%s' is NOT available.", command_name)
    return false
end

--- Проверяет существование системного файла.
-- @param string file_path Путь к файлу (например, "/proc/self/stat").
-- @return boolean true, если файл существует; false иначе.
local function check_system_file(file_path)
    local f = io.open(file_path, "r")
    if f then
        f:close()
        log_info(COMPONENT_NAME, "System file '%s' exists.", file_path)
        return true
    else
        log_error(COMPONENT_NAME, "System file '%s' does NOT exist.", file_path)
        return false
    end
end

--- Выполняет все проверки зависимостей.
-- @return boolean true, если все зависимости доступны; false иначе.
-- @return table Список сообщений об ошибках, если таковые имеются.
function InitChecker.check_dependencies()
    log_info(COMPONENT_NAME, "Starting dependency checks...")
    local all_ok = true
    local errors = {}

    local lua_modules = {
        "src.utils.logger",
        "src.adapters.dvb_tuner",
        "src.dispatchers.dvb_monitor_dispatcher",
        "src.config.monitor_config",
        "src.utils.utils",
        "src.channel.channel_monitor",
        "src.dispatchers.channel_monitor_dispatcher",
        "src.adapters.adapter",
        "src.config.monitor_settings",
    }

    local global_astra_functions = {
        "json.encode",
        "json.decode",
        "analyze",
        "dvb_tune",
        "kill_input",
        "string.split",
        "find_channel",
        "make_channel",
        "kill_channel",
        "http_request",
        "astra.version",
        "utils.hostname",
        "parse_url",
        "init_input",
    }

    local system_commands = {
        "nproc",
        "grep",
        "free",
        "awk",
        "cat",
    }

    local system_files = {
        "/proc/self/stat",
        "/proc/stat",
        "/proc/net/dev",
    }

    -- Проверка Lua-модулей
    for _, module_name in ipairs(lua_modules) do
        if not check_lua_module(module_name) then
            all_ok = false
            table.insert(errors, "Missing Lua module: " .. module_name)
        end
    end

    -- Проверка глобальных функций Astra
    for _, func_name in ipairs(global_astra_functions) do
        if not check_global_function(func_name) then
            all_ok = false
            table.insert(errors, "Missing Astra global function/variable: " .. func_name)
        end
    end

    -- Проверка системных команд
    for _, cmd_name in ipairs(system_commands) do
        if not check_system_command(cmd_name) then
            all_ok = false
            table.insert(errors, "Missing system command: " .. cmd_name)
        end
    end

    -- Проверка системных файлов
    for _, file_path in ipairs(system_files) do
        -- Для файлов /proc/%d/stat и /proc/%d/status мы не можем проверить их напрямую,
        -- так как %d - это PID. Проверим только базовые пути.
        if file_path ~= "/proc/%d/stat" and file_path ~= "/proc/%d/status" then
            if not check_system_file(file_path) then
                all_ok = false
                table.insert(errors, "Missing system file: " .. file_path)
            end
        end
    end

    if all_ok then
        log_info(COMPONENT_NAME, "All dependencies checked successfully.")
    else
        log_error(COMPONENT_NAME, "Dependency checks completed with errors.")
    end

    return all_ok, errors
end

return InitChecker
