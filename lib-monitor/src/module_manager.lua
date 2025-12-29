-- ===========================================================================
-- Модуль `module_manager`
--
-- Отвечает за централизованную загрузку модулей и валидацию их зависимостей,
-- обеспечивая корректный порядок инициализации компонентов библиотеки.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type, pairs, ipairs, tostring, pcall = type, pairs, ipairs, tostring, pcall
local table_concat, table_insert = table.concat, table.insert
local string_gmatch = string.gmatch

-- 2. Функции из ModuleManager.get_module()
-- Logger будет загружен позже, чтобы избежать циклической зависимости при инициализации ModuleManager
local Logger
local log_info = function(component, format_str, ...) if Logger and Logger.info then Logger.info(component, format_str, ...) end end
local log_error = function(component, format_str, ...) if Logger and Logger.error then Logger.error(component, format_str, ...) end end
local log_debug = function(component, format_str, ...) if Logger and Logger.debug then Logger.debug(component, format_str, ...) end end

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых глобальных зависимостей Astra, кроме тех, что управляются самим ModuleManager.

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ModuleManager"

-- 5. Инициализация объектов из загруженных модулей
local ModuleManager = {}
ModuleManager.__index = ModuleManager

local registered_modules = {}
local loaded_modules = {}
local global_dependencies = {}

-- Пост-инициализация Logger после того, как ModuleManager будет доступен
local function init_logger()
    if not Logger then
        -- Использовать require вместо ModuleManager.get_module для избежания рекурсии
        local success, logger_module = pcall(require, "src.utils.logger")
        if success and logger_module then
            Logger = logger_module
            log_info = Logger.info
            log_error = Logger.error
            log_debug = Logger.debug
        end
    end
end

--- Регистрирует модуль в ModuleManager.
-- @param string name Имя модуля (например, "utils.logger").
-- @param string path Путь к файлу модуля (например, "src.utils.logger").
-- @param table dependencies Таблица строк, содержащих имена зависимостей этого модуля.
function ModuleManager.register_module(name, path, dependencies)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Попытка зарегистрировать модуль с невалидным именем.")
        return
    end
    
    if not path or type(path) ~= "string" then
        log_error(COMPONENT_NAME, "Модуль '%s': путь должен быть строкой.", name)
        return
    end
    
    if registered_modules[name] then
        log_debug(COMPONENT_NAME, "Модуль '%s' уже зарегистрирован. Обновление информации.", name)
    end
    
    -- Валидация зависимостей
    local valid_dependencies = {}
    if dependencies and type(dependencies) == "table" then
        for _, dep in ipairs(dependencies) do
            if type(dep) == "string" and dep ~= "" then
                table_insert(valid_dependencies, dep)
            else
                log_error(COMPONENT_NAME, "Модуль '%s': игнорируем невалидную зависимость.", name)
            end
        end
    end
    
    registered_modules[name] = {
        path = path,
        dependencies = valid_dependencies
    }
    
    log_debug(COMPONENT_NAME, "Модуль '%s' зарегистрирован с зависимостями: %s.", 
             name, table_concat(valid_dependencies, ", "))
end

--- Вспомогательная функция для топологической сортировки с проверкой циклических зависимостей.
local function topological_sort()
    local load_order = {}
    local visited = {}
    local temp_visited = {}
    
    local function visit(name)
        if not registered_modules[name] then
            local msg = string.format("Попытка загрузить незарегистрированный модуль: %s.", name)
            if Logger then log_error(COMPONENT_NAME, msg) else print("[ERROR] " .. COMPONENT_NAME .. ": " .. msg) end
            return false
        end
        
        if visited[name] then
            return true
        end
        
        if temp_visited[name] then
            local msg = string.format("Обнаружена циклическая зависимость с участием модуля: %s.", name)
            if Logger then log_error(COMPONENT_NAME, msg) else print("[ERROR] " .. COMPONENT_NAME .. ": " .. msg) end
            return false
        end
        
        temp_visited[name] = true
        
        local module_info = registered_modules[name]
        for _, dep_name in ipairs(module_info.dependencies) do
            if not visit(dep_name) then
                return false
            end
        end
        
        temp_visited[name] = nil
        visited[name] = true
        
        -- Добавляем в порядке завершения (зависимости идут перед модулями, которые от них зависят)
        table_insert(load_order, name)
        return true
    end
    
    for name, _ in pairs(registered_modules) do
        if not visited[name] then
            if not visit(name) then
                return nil, "Ошибка циклической зависимости"
            end
        end
    end
    
    return load_order
end

--- Загружает все зарегистрированные модули в правильном порядке, разрешая зависимости.
function ModuleManager.load_modules()
    local load_order, err = topological_sort()
    
    if not load_order then
        local msg = string.format("Не удалось определить порядок загрузки: %s.", err)
        if Logger then log_error(COMPONENT_NAME, msg) else print("[ERROR] " .. COMPONENT_NAME .. ": " .. msg) end
        return false, err -- Возвращаем ошибку для отладки
    end
    
    if Logger then log_debug(COMPONENT_NAME, "Порядок загрузки модулей: %s.", table_concat(load_order, ", ")) end
    
    for _, name in ipairs(load_order) do
        -- Пропускаем уже загруженные модули
        if loaded_modules[name] then
            if Logger then log_debug(COMPONENT_NAME, "Модуль '%s' уже загружен, пропускаем.", name) end
            goto continue
        end
        
        local module_info = registered_modules[name]
        if Logger then log_debug(COMPONENT_NAME, "Загрузка модуля: %s (%s).", name, module_info.path) end
        
        local success, module_or_err = pcall(require, module_info.path)
        
        if not success then
            local msg = string.format("Ошибка при загрузке модуля '%s' из '%s': %s.", name, module_info.path, module_or_err)
            if Logger then log_error(COMPONENT_NAME, msg) else print("[ERROR] " .. COMPONENT_NAME .. ": " .. msg) end
            return false, msg -- Возвращаем ошибку для отладки
        end
        
        if module_or_err == nil then
            local msg = string.format("Модуль '%s' из '%s' вернул nil.", name, module_info.path)
            if Logger then log_error(COMPONENT_NAME, msg) else print("[ERROR] " .. COMPONENT_NAME .. ": " .. msg) end
            return false, msg -- Возвращаем ошибку для отладки
        end
        
        local module = module_or_err
        
        loaded_modules[name] = module

        if name == "utils.logger" and not Logger then
            init_logger()
        end

        if Logger then log_debug(COMPONENT_NAME, "Модуль '%s' успешно загружен.", name) end
        
        ::continue::
    end
    
    if Logger then log_debug(COMPONENT_NAME, "Все модули успешно загружены. Всего: %d.", #load_order) end
    return true
end

--- Возвращает загруженный модуль по его имени.
-- @param string name Имя модуля.
-- @return table Загруженный модуль или nil, если модуль не найден.
function ModuleManager.get_module(name)
    return loaded_modules[name]
end

--- Проверяет, что все зарегистрированные модули имеют удовлетворенные зависимости.
-- @return boolean true, если все зависимости удовлетворены, иначе false.
function ModuleManager.validate_dependencies()
    local all_dependencies_met = true
    
    for name, module_info in pairs(registered_modules) do
        for _, dep_name in ipairs(module_info.dependencies) do
            if not registered_modules[dep_name] then
                log_error(COMPONENT_NAME, "Модуль '%s' требует незарегистрированную зависимость: '%s'.", name, dep_name)
                all_dependencies_met = false
            end
        end
    end
    
    if all_dependencies_met then
        log_debug(COMPONENT_NAME, "Все внутренние зависимости зарегистрированных модулей удовлетворены.")
    else
        log_error(COMPONENT_NAME, "Обнаружены незарегистрированные внутренние зависимости.")
    end
    
    return all_dependencies_met
end

--- Проверяет наличие глобальной переменной или вложенной функции/таблицы.
-- @param string path_str Строка, представляющая путь к переменной/функции (например, "find_channel" или utils.version).
-- @return any, boolean Найденный объект и true, если переменная/функция существует, иначе nil и false.
function ModuleManager.check_nested_dependency(path_str)
    if not path_str or type(path_str) ~= "string" then
        log_error(COMPONENT_NAME, "Некорректный путь для проверки зависимости.")
        return nil, false
    end
    
    local parts = {}
    for part in string.gmatch(path_str, "[^.]+") do
        table_insert(parts, part)
    end
    
    if #parts == 0 then
        log_error(COMPONENT_NAME, "Пустой путь для проверки зависимости.")
        return nil, false
    end
    
    local current_scope = _G
    local full_path = ""
    local found_object = nil
    
    for i, part in ipairs(parts) do
        if i == 1 then
            full_path = part
        else
            full_path = full_path .. "." .. part
        end
        
        if type(current_scope) ~= "table" then
            log_debug(COMPONENT_NAME, "Зависимость '%s' не найдена на пути '%s' (не таблица).", path_str, full_path)
            return nil, false
        end
        
        if current_scope[part] == nil then
            log_debug(COMPONENT_NAME, "Зависимость '%s' не найдена на пути '%s'.", path_str, full_path)
            return nil, false
        end
        
        current_scope = current_scope[part]
        
        if i == #parts then
            found_object = current_scope
        end
    end
    
    log_debug(COMPONENT_NAME, "Вложенная зависимость '%s' найдена.", path_str)
    return found_object, true
end

--- Возвращает сохраненную ссылку на глобальную зависимость.
-- @param string name Имя зависимости.
-- @return any Сохраненный объект или nil, если зависимость не найдена.
function ModuleManager.get_global_dependency(name)
    return global_dependencies[name]
end

--- Удаляет сохраненную глобальную зависимость из кэша.
-- @param string name Имя зависимости.
-- @return boolean true, если зависимость была удалена.
function ModuleManager.remove_global_dependency(name)
    if global_dependencies[name] ~= nil then
        global_dependencies[name] = nil
        log_debug(COMPONENT_NAME, "Глобальная зависимость '%s' удалена из кэша.", name)
        return true
    end
    return false
end

--- Устанавливает глобальные зависимости.
-- @param table deps Таблица, где ключ - это путь к зависимости, значение - сам объект зависимости.
function ModuleManager.set_global_dependencies(deps)
    if type(deps) ~= "table" then
        log_error(COMPONENT_NAME, "Попытка установить глобальные зависимости с невалидным аргументом (ожидалась таблица).")
        return
    end
    for path, obj in pairs(deps) do
        global_dependencies[path] = obj
        log_debug(COMPONENT_NAME, "Глобальная зависимость '%s' установлена.", path)
    end
end

--- Получает список всех сохраненных глобальных зависимостей.
-- @return table Список путей к сохраненным зависимостям.
function ModuleManager.get_global_dependencies()
    local deps = {}
    for path, _ in pairs(global_dependencies) do
        table_insert(deps, path)
    end
    return deps
end

--- Проверяет, загружен ли модуль
-- @param string name Имя модуля
-- @return boolean true если модуль загружен, иначе false
function ModuleManager.is_module_loaded(name)
    return loaded_modules[name] ~= nil
end

--- Получает список всех зарегистрированных модулей
-- @return table Список имен модулей
function ModuleManager.get_registered_modules()
    local modules = {}
    for name in pairs(registered_modules) do
        table_insert(modules, name)
    end
    return modules
end

--- Получает список всех загруженных модулей
-- @return table Список имен загруженных модулей
function ModuleManager.get_loaded_modules()
    local modules = {}
    for name in pairs(loaded_modules) do
        table_insert(modules, name)
    end
    return modules
end

--- Очищает все зарегистрированные и загруженные модули (для тестов)
function ModuleManager.reset()
    registered_modules = {}
    loaded_modules = {}
    global_dependencies = {} -- Сбрасываем только Astra-специфичные зависимости
    log_debug(COMPONENT_NAME, "Состояние ModuleManager сброшено.")
end

-- Регистрируем себя в глобальном пространстве
_G.ModuleManager = ModuleManager

return ModuleManager
