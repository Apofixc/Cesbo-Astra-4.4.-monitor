-- ===========================================================================
-- Модуль `module_manager`
-- Отвечает за централизованную загрузку модулей и валидацию их зависимостей.
-- ===========================================================================

local type = type
local pairs = pairs
local ipairs = ipairs
local table_concat = table.concat
local table_insert = table.insert

-- Используем существующий Logger, если он доступен
local Logger
local function log_info(component, format_str, ...)
    if Logger and Logger.info then
        Logger.info(component, format_str, ...)
    end
end

local function log_error(component, format_str, ...)
    if Logger and Logger.error then
        Logger.error(component, format_str, ...)
    end
end

local function log_debug(component, format_str, ...)
    if Logger and Logger.debug then
        Logger.debug(component, format_str, ...)
    end
end

-- Пробуем загрузить Logger, но не падаем если его нет
local success, logger_module = pcall(require, "src.utils.logger")
if success then
    Logger = logger_module
end

local COMPONENT_NAME = "ModuleManager"

local ModuleManager = {}
ModuleManager.__index = ModuleManager

-- Таблица для хранения зарегистрированных модулей
local registered_modules = {}

-- Таблица для хранения загруженных модулей
local loaded_modules = {}

-- Таблица для хранения найденных глобальных зависимостей
local global_dependencies = {}

--- Регистрирует модуль в ModuleManager.
-- @param string name Имя модуля (например, "utils.logger").
-- @param string path Путь к файлу модуля (например, "src.utils.logger").
-- @param table dependencies Таблица строк, содержащих имена зависимостей этого модуля.
function ModuleManager.register_module(name, path, dependencies)
    if not name or type(name) ~= "string" then
        log_error(COMPONENT_NAME, "Попытка зарегистрировать модуль с невалидным именем")
        return
    end
    
    if not path or type(path) ~= "string" then
        log_error(COMPONENT_NAME, "Модуль '%s': путь должен быть строкой", name)
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
                log_error(COMPONENT_NAME, "Модуль '%s': игнорируем невалидную зависимость", name)
            end
        end
    end
    
    registered_modules[name] = {
        path = path,
        dependencies = valid_dependencies
    }
    
    log_debug(COMPONENT_NAME, "Модуль '%s' зарегистрирован с зависимостями: %s", 
             name, table_concat(valid_dependencies, ", "))
end

--- Вспомогательная функция для топологической сортировки с проверкой циклических зависимостей.
local function topological_sort()
    local load_order = {}
    local visited = {}
    local temp_visited = {}
    
    local function visit(name)
        if not registered_modules[name] then
            log_error(COMPONENT_NAME, "Попытка загрузить незарегистрированный модуль: %s", name)
            return false
        end
        
        if visited[name] then
            return true
        end
        
        if temp_visited[name] then
            log_error(COMPONENT_NAME, "Обнаружена циклическая зависимость с участием модуля: %s", name)
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
        log_error(COMPONENT_NAME, "Не удалось определить порядок загрузки: %s", err)
        return false
    end
    
    log_debug(COMPONENT_NAME, "Порядок загрузки модулей: %s", table_concat(load_order, ", "))
    
    for _, name in ipairs(load_order) do
        -- Пропускаем уже загруженные модули
        if loaded_modules[name] then
            log_debug(COMPONENT_NAME, "Модуль '%s' уже загружен, пропускаем", name)
            goto continue
        end
        
        local module_info = registered_modules[name]
        log_debug(COMPONENT_NAME, "Загрузка модуля: %s (%s)", name, module_info.path)
        
        local success, module_or_err = pcall(require, module_info.path)
        
        if not success then
            log_error(COMPONENT_NAME, "Ошибка при загрузке модуля '%s' из '%s': %s", name, module_info.path, module_or_err)
            return false
        end
        
        if module_or_err == nil then
            log_error(COMPONENT_NAME, "Модуль '%s' из '%s' вернул nil", name, module_info.path)
            return false
        end
        
        local module = module_or_err
        
        loaded_modules[name] = module
        log_debug(COMPONENT_NAME, "Модуль '%s' успешно загружен", name)
        
        ::continue::
    end
    
    log_debug(COMPONENT_NAME, "Все модули успешно загружены. Всего: %d", #load_order)
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
                log_error(COMPONENT_NAME, "Модуль '%s' требует незарегистрированную зависимость: '%s'", name, dep_name)
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
        log_error(COMPONENT_NAME, "Некорректный путь для проверки зависимости")
        return nil, false
    end
    
    local parts = {}
    for part in string.gmatch(path_str, "[^.]+") do
        table_insert(parts, part)
    end
    
    if #parts == 0 then
        log_error(COMPONENT_NAME, "Пустой путь для проверки зависимости")
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
            log_debug(COMPONENT_NAME, "Зависимость '%s' не найдена на пути '%s' (не таблица)", path_str, full_path)
            return nil, false
        end
        
        if current_scope[part] == nil then
            log_debug(COMPONENT_NAME, "Зависимость '%s' не найдена на пути '%s'", path_str, full_path)
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
        log_debug(COMPONENT_NAME, "Глобальная зависимость '%s' удалена из кэша", name)
        return true
    end
    return false
end

--- Устанавливает глобальные зависимости.
-- @param table deps Таблица, где ключ - это путь к зависимости, значение - сам объект зависимости.
function ModuleManager.set_global_dependencies(deps)
    if type(deps) ~= "table" then
        log_error(COMPONENT_NAME, "Попытка установить глобальные зависимости с невалидным аргументом (ожидалась таблица)")
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
    log_debug(COMPONENT_NAME, "Состояние ModuleManager сброшено")
end

-- Регистрируем себя в глобальном пространстве
_G.ModuleManager = ModuleManager

return ModuleManager