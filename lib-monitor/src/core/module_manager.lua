-- ===========================================================================
-- Модуль `module_manager`
--
-- Отвечает за централизованную загрузку модулей и валидацию их зависимостей,
-- обеспечивая корректный порядок инициализации компонентов библиотеки.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type = _G.type
local pairs = _G.pairs
local ipairs = _G.ipairs
local tostring = _G.tostring
local pcall = _G.pcall
local table_concat = _G.table.concat
local table_insert = _G.table.insert
local table_remove = _G.table.remove
local string_gmatch = _G.string.gmatch
local string_format = _G.string.format
local string_match = _G.string.match

-- 2. Функции из ModuleManager.get_module()
-- ModuleManager является корнем системы и не использует get_module для себя.

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Глобальные зависимости Astra управляются самим ModuleManager.

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ModuleManager"

-- 5. Внутреннее состояние (Private State)

--- @class ModuleManager
local ModuleManager = {}

--- @class ModuleInfo
--- @field path string Путь к файлу модуля
--- @field dependencies string[] Список имен зависимостей

--- @type table<string, ModuleInfo> Реестр зарегистрированных модулей
local _registered_modules = {}

--- @type table<string, any> Кэш загруженных экземпляров модулей
local _loaded_modules = {}

--- @type table<string, any> Хранилище глобальных зависимостей Astra
local _global_dependencies = {}

--- @type table<string, any> Кэш для ускорения поиска вложенных зависимостей
local _nested_dependency_cache = {}

--- @type table<string, string[]> Кэш разобранных путей зависимостей
local _path_parts_cache = {}

--- @type boolean Флаг блокировки изменений во время загрузки
local _is_loading = false

--- @type table Прокси-объект для логгера, обеспечивающий доступ даже после сброса состояния
local _LoggerProxy = setmetatable({}, {
    __index = function(_, key)
        local Logger = _loaded_modules["logger"]
        if Logger and Logger[key] then
            return Logger[key]
        end
        return nil
    end
})

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

--- Прокси-функция для логирования информационных сообщений
--- @param component string Имя компонента
--- @param format_str string Строка формата
--- @param ... any Аргументы форматирования
local function _log_info(component, format_str, ...)
    if _LoggerProxy.info then _LoggerProxy.info(component, format_str, ...) end
end

--- Прокси-функция для логирования ошибок
--- @param component string Имя компонента
--- @param format_str string Строка формата
--- @param ... any Аргументы форматирования
local function _log_error(component, format_str, ...)
    if _LoggerProxy.error then
        _LoggerProxy.error(component, format_str, ...)
    else
        -- Fallback до инициализации логгера
        print(string_format("[%s][ERROR] %s", component, string_format(format_str, ...)))
    end
end

--- Прокси-функция для логирования отладочных сообщений
--- @param component string Имя компонента
--- @param format_str string Строка формата
--- @param ... any Аргументы форматирования
local function _log_debug(component, format_str, ...)
    if _LoggerProxy.debug then _LoggerProxy.debug(component, format_str, ...) end
end

--- Реализует итеративный алгоритм топологической сортировки для определения порядка загрузки.
--- Использование итеративного подхода исключает риск переполнения стека (stack overflow)
--- и позволяет корректно обрабатывать графы любой глубины.
--- @private
--- @return string[]|nil Список имен модулей в порядке загрузки или nil при ошибке (цикл)
local function _topological_sort()
    local load_order = {}
    local visited = {}
    local in_stack = {}
    local keys = {}
    
    -- Получаем список всех ключей для стабильной итерации (микро-оптимизация)
    for name in pairs(_registered_modules) do
        keys[#keys + 1] = name
    end

    for i = 1, #keys do
        local root_name = keys[i]
        if not visited[root_name] then
            -- Стек для итеративного DFS: { {name, next_dep_index}, ... }
            local stack = { { root_name, 1 } }
            in_stack[root_name] = true
            
            while #stack > 0 do
                local current = stack[#stack]
                local name = current[1]
                local module_info = _registered_modules[name]
                
                if not module_info then
                    _log_error(COMPONENT_NAME, "Модуль '%s' не зарегистрирован, но указан как зависимость.", name)
                    return nil
                end

                local deps = module_info.dependencies
                local found_new_dep = false
                
                -- Проверяем зависимости, начиная с сохраненного индекса
                for j = current[2], #deps do
                    local dep_name = deps[j]
                    if not visited[dep_name] then
                        if in_stack[dep_name] then
                            -- Обнаружен цикл. Формируем путь для отчета.
                            local cycle_path = {}
                            local start_collect = false
                            for k = 1, #stack do
                                if stack[k][1] == dep_name then start_collect = true end
                                if start_collect then cycle_path[#cycle_path + 1] = stack[k][1] end
                            end
                            cycle_path[#cycle_path + 1] = dep_name
                            _log_error(COMPONENT_NAME, "Обнаружена циклическая зависимость: %s", 
                                table_concat(cycle_path, " -> "))
                            return nil
                        end
                        
                        -- Сохраняем прогресс текущего модуля и переходим к зависимости
                        current[2] = j + 1
                        stack[#stack + 1] = { dep_name, 1 }
                        in_stack[dep_name] = true
                        found_new_dep = true
                        break
                    end
                end

                if not found_new_dep then
                    -- Все зависимости модуля обработаны
                    visited[name] = true
                    in_stack[name] = nil
                    load_order[#load_order + 1] = name
                    table_remove(stack)
                end
            end
        end
    end

    return load_order
end

-- ===========================================================================
-- Публичное API (Public API)
-- ===========================================================================

--- Регистрирует модуль в системе.
--- @param name string Уникальное имя модуля (например, "utils.logger").
--- @param path string Путь для require (например, "astra.lib-monitor.src.utils.logger").
--- @param dependencies string[]|nil Список имен модулей, от которых зависит данный модуль.
--- @return boolean Статус выполнения
function ModuleManager.register_module(name, path, dependencies)
    if _is_loading then
        _log_error(COMPONENT_NAME, "Регистрация модуля '%s' отклонена: процесс загрузки уже запущен.", name)
        return false
    end

    if not name or type(name) ~= "string" or name == "" then
        _log_error(COMPONENT_NAME, "Попытка регистрации модуля с некорректным именем.")
        return false
    end

    if not path or type(path) ~= "string" or path == "" then
        _log_error(COMPONENT_NAME, "Модуль '%s': путь должен быть непустой строкой.", name)
        return false
    end
    
    -- Валидация формата пути (базовая проверка на отсутствие подозрительных символов)
    if string_match(path, "[^%w%._%-/]") then
        _log_error(COMPONENT_NAME, "Модуль '%s': путь содержит недопустимые символы.", name)
        return false
    end

    -- Валидация и фильтрация списка зависимостей (ленивая инициализация таблицы)
    local valid_dependencies = nil
    if dependencies and type(dependencies) == "table" and #dependencies > 0 then
        valid_dependencies = {}
        for i = 1, #dependencies do
            local dep = dependencies[i]
            if type(dep) == "string" and dep ~= "" then
                valid_dependencies[#valid_dependencies + 1] = dep
            end
        end
    end

    _registered_modules[name] = {
        path = path,
        dependencies = valid_dependencies or {}
    }

    _log_debug(COMPONENT_NAME, "Модуль '%s' зарегистрирован.", name)
    return true
end

--- Загружает все зарегистрированные модули в правильном порядке.
--- @return string[]|nil Список имен успешно загруженных модулей или nil при критической ошибке.
function ModuleManager.load_modules()
    if _is_loading then
        _log_error(COMPONENT_NAME, "Вызов load_modules отклонен: загрузка уже выполняется.")
        return nil
    end

    _is_loading = true

    -- Проверка версии Lua согласно стандартам проекта (lua-version.md)
    if _VERSION ~= "Lua 5.2" then
        _log_error(COMPONENT_NAME, "Внимание: версия Lua %s отличается от целевой (5.2).", _VERSION)
    end

    local load_order = _topological_sort()
    if not load_order then
        _is_loading = false
        return nil
    end

    for i = 1, #load_order do
        local name = load_order[i]
        if not _loaded_modules[name] then
            local module_info = _registered_modules[name]
            _log_debug(COMPONENT_NAME, "Загрузка: %s (%s).", name, module_info.path)

            local success, module_or_err = pcall(require, module_info.path)

            if not success then
                _log_error(COMPONENT_NAME, "Ошибка загрузки модуля '%s' (%s): %s.",
                    name, module_info.path, tostring(module_or_err))
                _is_loading = false
                return nil
            end

            if module_or_err == nil then
                _log_error(COMPONENT_NAME, "Модуль '%s' вернул nil при загрузке.", name)
                _is_loading = false
                return nil
            end

            _loaded_modules[name] = module_or_err
            _log_debug(COMPONENT_NAME, "Модуль '%s' успешно загружен.", name)
        end
    end

    _is_loading = false
    _log_info(COMPONENT_NAME, "Все модули успешно загружены. Всего: %d.", #load_order)
    return load_order
end

--- Возвращает экземпляр загруженного модуля.
--- @param name string Имя модуля.
--- @return any|nil Экземпляр модуля или nil, если он не загружен.
function ModuleManager.get_module(name)
    return _loaded_modules[name]
end

--- Проверяет целостность графа зависимостей (все ли зависимости зарегистрированы).
--- @return boolean true, если все зависимости найдены в реестре.
function ModuleManager.validate_dependencies()
    local all_met = true
    for name, module_info in pairs(_registered_modules) do
        local deps = module_info.dependencies
        for i = 1, #deps do
            local dep_name = deps[i]
            if not _registered_modules[dep_name] then
                _log_error(COMPONENT_NAME, "Модуль '%s' требует незарегистрированную зависимость: '%s'.", name, dep_name)
                all_met = false
            end
        end
    end
    return all_met
end

--- Динамически проверяет наличие вложенной зависимости в глобальном окружении.
--- Использует двухуровневое кэширование (пути и объекты) для максимальной производительности.
--- @param path_str string Путь к объекту (например, "astra.reload").
--- @return any|nil Найденный объект или nil.
function ModuleManager.check_nested_dependency(path_str)
    if not path_str or type(path_str) ~= "string" then return nil end

    -- 1. Проверка кэша объектов
    if _nested_dependency_cache[path_str] ~= nil then
        return _nested_dependency_cache[path_str]
    end

    -- 2. Получение или создание кэша разобранного пути
    local parts = _path_parts_cache[path_str]
    if not parts then
        parts = {}
        for part in string_gmatch(path_str, "[^.]+") do
            parts[#parts + 1] = part
        end
        _path_parts_cache[path_str] = parts
    end

    -- 3. Поиск объекта
    local current_scope = _G
    for i = 1, #parts do
        local part = parts[i]
        if type(current_scope) ~= "table" or current_scope[part] == nil then
            _log_debug(COMPONENT_NAME, "Зависимость '%s' не найдена на уровне '%s'.", path_str, part)
            return nil
        end
        current_scope = current_scope[part]
    end

    _nested_dependency_cache[path_str] = current_scope
    _log_debug(COMPONENT_NAME, "Вложенная зависимость '%s' найдена.", path_str)
    return current_scope
end

--- Возвращает сохраненную ссылку на глобальную зависимость Astra.
--- @param name string Имя зависимости.
--- @return any|nil Объект зависимости или nil.
function ModuleManager.get_global_dependency(name)
    return _global_dependencies[name]
end

--- Удаляет глобальную зависимость из кэша.
--- @param name string Имя зависимости.
--- @return boolean true, если зависимость была удалена.
function ModuleManager.remove_global_dependency(name)
    if _global_dependencies[name] ~= nil then
        _global_dependencies[name] = nil
        _log_debug(COMPONENT_NAME, "Глобальная зависимость '%s' удалена.", name)
        return true
    end
    return false
end

--- Регистрирует набор глобальных зависимостей.
--- @param deps table<string, any> Таблица зависимостей.
--- @return boolean Статус выполнения.
function ModuleManager.set_global_dependencies(deps)
    if type(deps) ~= "table" then
        _log_error(COMPONENT_NAME, "set_global_dependencies: ожидалась таблица.")
        return false
    end
    for path, obj in pairs(deps) do
        _global_dependencies[path] = obj
        _log_debug(COMPONENT_NAME, "Глобальная зависимость '%s' установлена.", path)
    end
    return true
end

--- Возвращает список имен всех зарегистрированных глобальных зависимостей.
--- @return string[]
function ModuleManager.get_global_dependencies()
    local deps = {}
    for path in pairs(_global_dependencies) do
        deps[#deps + 1] = path
    end
    return deps
end

--- Проверяет, загружен ли конкретный модуль.
--- @param name string Имя модуля.
--- @return boolean
function ModuleManager.is_module_loaded(name)
    return _loaded_modules[name] ~= nil
end

--- Возвращает список имен всех зарегистрированных модулей.
--- @return string[]
function ModuleManager.get_registered_modules()
    local modules = {}
    for name in pairs(_registered_modules) do
        modules[#modules + 1] = name
    end
    return modules
end

--- Возвращает список имен всех загруженных модулей.
--- @return string[]
function ModuleManager.get_loaded_modules()
    local modules = {}
    for name in pairs(_loaded_modules) do
        modules[#modules + 1] = name
    end
    return modules
end

--- Сбрасывает состояние менеджера (используется преимущественно в тестах).
function ModuleManager.reset()
    if _is_loading then
        _log_error(COMPONENT_NAME, "Сброс состояния запрещен во время загрузки модулей.")
        return
    end
    _registered_modules = {}
    _loaded_modules = {}
    _global_dependencies = {}
    _nested_dependency_cache = {}
    _path_parts_cache = {}
    _log_debug(COMPONENT_NAME, "Состояние ModuleManager сброшено.")
end

-- Экспорт в глобальную область видимости для удобства доступа из скриптов Astra
_G.ModuleManager = ModuleManager

return ModuleManager
