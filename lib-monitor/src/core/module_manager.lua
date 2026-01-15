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
local string_gmatch = _G.string.gmatch
local string_format = _G.string.format

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

--- @type table|nil Ссылка на модуль Logger (инициализируется лениво)
local _Logger = nil

-- ===========================================================================
-- Внутренние функции (Private)
-- ===========================================================================

--- Прокси-функция для логирования информационных сообщений
--- @param component string Имя компонента
--- @param format_str string Строка формата
--- @param ... any Аргументы форматирования
local function _log_info(component, format_str, ...)
    if _Logger and _Logger.info then _Logger.info(component, format_str, ...) end
end

--- Прокси-функция для логирования ошибок
--- @param component string Имя компонента
--- @param format_str string Строка формата
--- @param ... any Аргументы форматирования
local function _log_error(component, format_str, ...)
    if _Logger and _Logger.error then
        _Logger.error(component, format_str, ...)
    else
        print(string_format("[%s][ERROR] %s", component, string_format(format_str, ...)))
    end
end

--- Прокси-функция для логирования отладочных сообщений
--- @param component string Имя компонента
--- @param format_str string Строка формата
--- @param ... any Аргументы форматирования
local function _log_debug(component, format_str, ...)
    if _Logger and _Logger.debug then _Logger.debug(component, format_str, ...) end
end

--- Выполняет ленивую инициализацию логгера после загрузки соответствующего модуля.
--- Это необходимо для разрыва циклической зависимости, так как Logger сам зависит от ModuleManager.
--- @private
local function _init_logger()
    if not _Logger then
        local module_info = _registered_modules["logger"]
        if not module_info then return end

        -- Используем прямой require для предотвращения рекурсии в get_module
        local success, logger_module = pcall(require, module_info.path)
        if success and logger_module then
            _Logger = logger_module
        end
    end
end

--- Реализует алгоритм топологической сортировки (DFS) для определения порядка загрузки.
--- @private
--- @return string[]|nil Список имен модулей в порядке загрузки или nil при ошибке (цикл)
local function _topological_sort()
    local load_order = {}
    local visited = {}
    local temp_visited = {}

    --- Рекурсивный обход графа зависимостей
    --- @param name string Имя модуля
    --- @return boolean Успех обхода
    local function visit(name)
        if not _registered_modules[name] then
            _log_error(COMPONENT_NAME, "Попытка загрузить незарегистрированный модуль: %s.", name)
            return false
        end

        if visited[name] then
            return true
        end

        if temp_visited[name] then
            _log_error(COMPONENT_NAME, "Обнаружена циклическая зависимость с участием модуля: %s.", name)
            return false
        end

        temp_visited[name] = true

        local module_info = _registered_modules[name]
        for _, dep_name in ipairs(module_info.dependencies) do
            if not visit(dep_name) then
                return false
            end
        end

        temp_visited[name] = nil
        visited[name] = true

        -- Добавляем в список после посещения всех зависимостей
        table_insert(load_order, name)
        return true
    end

    for name, _ in pairs(_registered_modules) do
        if not visited[name] then
            if not visit(name) then
                return nil
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
    if not name or type(name) ~= "string" then
        _log_error(COMPONENT_NAME, "Попытка зарегистрировать модуль с некорректным именем.")
        return false
    end

    if not path or type(path) ~= "string" then
        _log_error(COMPONENT_NAME, "Модуль '%s': путь должен быть строкой.", name)
        return false
    end

    if _registered_modules[name] then
        _log_debug(COMPONENT_NAME, "Модуль '%s' уже зарегистрирован. Обновление информации.", name)
    end

    -- Валидация и фильтрация списка зависимостей
    local valid_dependencies = {}
    if dependencies and type(dependencies) == "table" then
        for _, dep in ipairs(dependencies) do
            if type(dep) == "string" and dep ~= "" then
                table_insert(valid_dependencies, dep)
            else
                _log_error(COMPONENT_NAME, "Модуль '%s': игнорируем некорректную зависимость.", name)
            end
        end
    end

    _registered_modules[name] = {
        path = path,
        dependencies = valid_dependencies
    }

    _log_debug(COMPONENT_NAME, "Модуль '%s' зарегистрирован. Зависимости: %s.",
             name, table_concat(valid_dependencies, ", "))
    return true
end

--- Загружает все зарегистрированные модули в правильном порядке.
--- @return string[]|nil Список имен успешно загруженных модулей или nil при критической ошибке.
function ModuleManager.load_modules()
    -- Проверка версии Lua согласно стандартам проекта (lua-version.md)
    if _VERSION ~= "Lua 5.2" then
        _log_error(COMPONENT_NAME, "Неподдерживаемая версия Lua: %s. Ожидается Lua 5.2.", _VERSION)
    end

    local load_order = _topological_sort()

    if not load_order then
        _log_error(COMPONENT_NAME, "Не удалось определить порядок загрузки из-за ошибок в зависимостях.")
        return nil
    end

    _log_debug(COMPONENT_NAME, "Порядок загрузки модулей: %s.", table_concat(load_order, ", "))

    for _, name in ipairs(load_order) do
        if not _loaded_modules[name] then
            local module_info = _registered_modules[name]
            _log_debug(COMPONENT_NAME, "Загрузка модуля: %s (%s).", name, module_info.path)

            local success, module_or_err = pcall(require, module_info.path)

            if not success then
                _log_error(COMPONENT_NAME, "Ошибка при загрузке модуля '%s' (%s): %s.",
                    name, module_info.path, tostring(module_or_err))
                return nil
            end

            if module_or_err == nil then
                _log_error(COMPONENT_NAME, "Модуль '%s' вернул nil при загрузке.", name)
                return nil
            end

            _loaded_modules[name] = module_or_err

            -- Специальная обработка для логгера для включения расширенного логирования
            if name == "logger" and not _Logger then
                _init_logger()
            end

            _log_debug(COMPONENT_NAME, "Модуль '%s' успешно загружен.", name)
        end
    end

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
        for _, dep_name in ipairs(module_info.dependencies) do
            if not _registered_modules[dep_name] then
                _log_error(COMPONENT_NAME, "Модуль '%s' требует незарегистрированную зависимость: '%s'.", name, dep_name)
                all_met = false
            end
        end
    end

    return all_met
end

--- Динамически проверяет наличие вложенной зависимости в глобальном окружении.
--- Использует кэширование для оптимизации повторных проверок.
--- @param path_str string Путь к объекту (например, "astra.reload").
--- @return any|nil Найденный объект или nil.
function ModuleManager.check_nested_dependency(path_str)
    if not path_str or type(path_str) ~= "string" then
        _log_error(COMPONENT_NAME, "Некорректный путь для проверки зависимости.")
        return nil
    end

    if _nested_dependency_cache[path_str] ~= nil then
        return _nested_dependency_cache[path_str]
    end

    local current_scope = _G
    for part in string_gmatch(path_str, "[^.]+") do
        if type(current_scope) ~= "table" or current_scope[part] == nil then
            _log_debug(COMPONENT_NAME, "Зависимость '%s' не найдена.", path_str)
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
        _log_error(COMPONENT_NAME, "Ожидалась таблица зависимостей.")
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
    for path, _ in pairs(_global_dependencies) do
        table_insert(deps, path)
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
        table_insert(modules, name)
    end
    return modules
end

--- Возвращает список имен всех загруженных модулей.
--- @return string[]
function ModuleManager.get_loaded_modules()
    local modules = {}
    for name in pairs(_loaded_modules) do
        table_insert(modules, name)
    end
    return modules
end

--- Сбрасывает состояние менеджера (используется преимущественно в тестах).
function ModuleManager.reset()
    _registered_modules = {}
    _loaded_modules = {}
    _global_dependencies = {}
    _nested_dependency_cache = {}
    _Logger = nil
    _log_debug(COMPONENT_NAME, "Состояние ModuleManager сброшено.")
end

-- Экспорт в глобальную область видимости для удобства доступа из скриптов Astra
_G.ModuleManager = ModuleManager

return ModuleManager
