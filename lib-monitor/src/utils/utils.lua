-- ===========================================================================
-- Модуль `utils.utils`
--
-- Предоставляет набор вспомогательных утилит и функций, используемых
-- в различных компонентах системы мониторинга. Включает функции для
-- работы со строками, таблицами, валидации параметров и отправки данных.
-- ===========================================================================

-- 1. Стандартные Lua функции
local type, tostring, ipairs, pairs = type, tostring, ipairs, pairs
local string_format = string.format
local math_max, math_abs = math.max, math.abs

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local log_info = Logger.info
local log_error = Logger.error
local log_debug = Logger.debug
local config = ModuleManager.get_module("monitor_settings")
local MonitorConfig = ModuleManager.get_module("monitor_config")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local http_request = ModuleManager.get_global_dependency("http_request")
local astra_version = ModuleManager.get_global_dependency("astra.version")
local hostname = ModuleManager.get_global_dependency("utils.hostname")()

-- 4. Константы и конфигурации
local COMPONENT_NAME = "Utils"
local STREAM = config.STREAM or {}
local MONIT_ADDRESS = config.MONIT_ADDRESS or {}
local DEFAULT_FEEDS = {"channels", "analyze", "errors", "psi", "dvb"}

-- 5. Инициализация объектов из загруженных модулей
-- Нет объектов для инициализации в этом модуле

-- ===========================================================================
-- Основные функции модуля
-- ===========================================================================

--- Возвращает имя потока по IP-адресу, используя предопределенную карту STREAM.
--- Если IP-адрес не найден в карте, возвращает сам IP-адрес.
--- @param ip_address string IP-адрес потока.
--- @return boolean success Статус выполнения
--- @return string|nil result Имя потока или исходный IP-адрес
function get_stream(ip_address)
    if type(ip_address) ~= "string" or not ip_address then
        local error_msg = string_format("Недопустимый ip_address: должна быть непустая строка. Получено: %s.", tostring(ip_address))
        log_error(COMPONENT_NAME, error_msg)
        return false, error_msg
    end

    return true, STREAM[ip_address] or ip_address
end

--- Вычисляет отношение абсолютной разницы между двумя числами к их максимальному значению.
--- Используется для определения относительного изменения.
--- @param old number Старое значение.
--- @param new number Новое значение.
--- @return boolean success Статус выполнения
--- @return number|string result Отношение (от 0 до 1) или сообщение об ошибке
function ratio(old, new)
    if type(old) ~= "number" or type(new) ~= "number" then
        local error_msg = string_format("Недопустимые типы: old и new должны быть числами. Получено old: %s, new: %s.", type(old), type(new))
        log_error(COMPONENT_NAME, error_msg)
        return false, error_msg
    end
    
    local abs_old = math_abs(old)
    local abs_new = math_abs(new)
    local max_abs = math_max(abs_old, abs_new)

    if max_abs == 0 then
        return true, 0
    elseif abs_old == 0 or abs_new == 0 then
        return true, 1
    end

    return true, math_abs(old - new) / max_abs
end

--- Создает поверхностную копию таблицы.
--- @param t table Исходная таблица.
--- @return boolean success Статус выполнения
--- @return table|string result Копия таблицы или сообщение об ошибке
local shallow_table_copy = function(t)
    if type(t) ~= "table" then
        local error_msg = string_format("Недопустимый аргумент: должна быть таблица. Получено: %s.", type(t))
        log_error(COMPONENT_NAME, error_msg)
        return false, error_msg
    end

    local copy = {}
    for k, v in pairs(t) do
        copy[k] = v
    end

    return true, copy
end

--- Вспомогательная функция для валидации общих параметров мониторинга.
--- @param host string Хост.
--- @param port number Порт.
--- @param path string Путь.
--- @param [feed] string|nil Имя клиента.
--- @return boolean success Статус выполнения
--- @return string|nil result Сообщение об ошибке или nil
local function validate_monitoring_params(host, port, path, feed)
    if not (type(host) == "string" and host ~= "") then
        local error_msg = string_format("Хост должен быть непустой строкой. Получено: %s.", tostring(host))
        log_error(COMPONENT_NAME, "[validate_monitoring_params] %s", error_msg)
        return false, error_msg
    end

    if not (type(port) == "number" and port > 0) then
        local error_msg = string_format("Порт должен быть положительным числом. Получено: %s.", tostring(port))
        log_error(COMPONENT_NAME, "[validate_monitoring_params] %s", error_msg)
        return false, error_msg
    end

    if not (type(path) == "string" and path ~= "") then
        local error_msg = string_format("Путь должен быть непустой строкой. Получено: %s.", tostring(path))
        log_error(COMPONENT_NAME, "[validate_monitoring_params] %s", error_msg)
        return false, error_msg
    end

    if feed and not (type(feed) == "string" and feed ~= "") then
        local error_msg = string_format("Feed должен быть непустой строкой, если предоставлен. Получено: %s.", tostring(feed))
        log_error(COMPONENT_NAME, "[validate_monitoring_params] %s", error_msg)
        return false, error_msg
    end
    return true
end

--- Валидирует параметр монитора на основе его имени, значения и типа/диапазона, используя схему.
--- @param name string Имя параметра.
--- @param value any Значение параметра для валидации.
--- @return boolean success Статус выполнения
--- @return any|string result Валидное значение параметра или сообщение об ошибке
function validate_monitor_param(name, value)
    local schema = MonitorConfig.ValidationSchema[name]
    if not schema then
        local error_msg = string_format("Неизвестный параметр монитора в схеме: %s.", name)
        log_error(COMPONENT_NAME, error_msg)
        return false, error_msg
    end

    if value == nil then
        return true, schema.default -- Используем значение по умолчанию из схемы
    end

    if type(value) ~= schema.type then
        local error_msg = string_format("Недопустимый тип для '%s': ожидалось %s, получено %s.", name, schema.type, type(value))
        log_error(COMPONENT_NAME, error_msg)
        return false, error_msg
    end

    if schema.type == "number" then
        if schema.min ~= nil and value < schema.min then
            local error_msg = string_format("Значение для '%s' (%s) меньше минимально допустимого (%s).", name, tostring(value), tostring(schema.min))
            log_error(COMPONENT_NAME, error_msg)
            return false, error_msg
        end
        if schema.max ~= nil and value > schema.max then
            local error_msg = string_format("Значение для '%s' (%s) больше максимально допустимого (%s).", name, tostring(value), tostring(schema.max))
            log_error(COMPONENT_NAME, error_msg)
            return false, error_msg
        end
    end

    return true, value
end

--- Вспомогательная функция для валидации имени монитора.
--- Имя монитора должно быть непустой строкой, содержать только буквенно-цифровые символы,
--- дефисы, подчеркивания и точки, а также иметь ограниченную длину.
--- @param name string Имя монитора.
--- @return boolean success Статус выполнения
--- @return string|nil result Сообщение об ошибке или nil
function validate_monitor_name(name)
    if not name or type(name) ~= "string" or name == "" then
        local error_msg = string_format("Недопустимое имя монитора: ожидалась непустая строка, получено: %s.", tostring(name))
        log_error(COMPONENT_NAME, error_msg)
        return false, error_msg
    end

    -- Проверка на допустимые символы (буквы, цифры, дефисы, подчеркивания, точки)
    if not name:match("^[a-zA-Z0-9%._-]+$") then
        local error_msg = "Недопустимое имя монитора: содержит запрещенные символы. Разрешены только буквенно-цифровые символы, дефисы, подчеркивания и точки."
        log_error(COMPONENT_NAME, error_msg)
        return false, error_msg
    end

    -- Проверка на максимальную длину имени
    if #name > MonitorConfig.MaxMonitorNameLength then
        local error_msg = string_format("Недопустимое имя монитора: длина (%s) превышает максимально допустимую (%s).", #name, MonitorConfig.MaxMonitorNameLength)
        log_error(COMPONENT_NAME, error_msg)
        return false, error_msg
    end

    return true
end

--- Устанавливает или переопределяет адрес мониторинга для клиентов.
--- @param host string Хост для мониторинга.
--- @param port number Порт для мониторинга.
--- @param path string Путь для мониторинга.
--- @param [feed] string|nil Имя клиента (например, "channels", "analyze"). Если не указано, обновляет все стандартные клиенты.
--- @return boolean success Статус выполнения
--- @return string|nil result Сообщение об ошибке или nil
function set_client_monitoring(host, port, path, feed)
    local is_valid, validation_err = validate_monitoring_params(host, port, path, feed)
    if not is_valid then
        return false, validation_err
    end

    if feed then
        -- Убедиться, что MONIT_ADDRESS[feed] является таблицей
        if type(MONIT_ADDRESS[feed]) ~= "table" then
            MONIT_ADDRESS[feed] = {}
        end

        local new_address = {host = host, port = port, path = path}
        local is_duplicate = false
        for _, existing_addr in ipairs(MONIT_ADDRESS[feed]) do
            if existing_addr.host == new_address.host and existing_addr.port == new_address.port and existing_addr.path == new_address.path then
                is_duplicate = true
                break
            end
        end

        if is_duplicate then
            log_info(COMPONENT_NAME, "Адрес мониторинга для клиента '%s' с host=%s, port=%s, path=%s уже существует. Пропуск добавления.", feed, host, tostring(port), path)
        else
            table.insert(MONIT_ADDRESS[feed], new_address)
            log_info(COMPONENT_NAME, "Добавлен адрес мониторинга для клиента '%s' с host=%s, port=%s, path=%s.", feed, host, tostring(port), path)
        end
    else
        for _, feed_name in ipairs(DEFAULT_FEEDS) do
            -- Очистить существующий список и добавить новый адрес
            MONIT_ADDRESS[feed_name] = {{host = host, port = port, path = path}}
            log_info(COMPONENT_NAME, "Установлен адрес мониторинга по умолчанию для клиента '%s' с host=%s, port=%s, path=%s.", feed_name, host, tostring(port), path)
        end
    end

    return true, nil
end

--- Удаляет конкретный адрес мониторинга для клиента.
--- @param host string Хост для удаления.
--- @param port number Порт для удаления.
--- @param path string Путь для удаления.
--- @param feed string Имя клиента (например, "channels", "analyze").
--- @return boolean success Статус выполнения
--- @return string|nil result Сообщение об ошибке или nil
function remove_client_monitoring(host, port, path, feed)
    local is_valid, validation_err = validate_monitoring_params(host, port, path, feed)
    if not is_valid then
        return false, validation_err
    end

    local recipients = MONIT_ADDRESS[feed]
    if not recipients or #recipients == 0 then
        local err = string_format("Адреса мониторинга для клиента '%s' не найдены.", feed)
        log_info(COMPONENT_NAME, err)
        return false, err
    end

    local removed = false
    for i = #recipients, 1, -1 do
        local addr = recipients[i]
        if addr.host == host and addr.port == port and addr.path == path then
            table.remove(recipients, i)
            removed = true
            log_info(COMPONENT_NAME, "Удален адрес мониторинга для клиента '%s' с host=%s, port=%s, path=%s.", feed, host, tostring(port), path)
            break
        end
    end

    if not removed then
        local error_msg = string_format("Адрес мониторинга для клиента '%s' с host=%s, port=%s, path=%s не найден.", feed, host, tostring(port), path)
        log_info(COMPONENT_NAME, error_msg)
        return false, error_msg
    end

    return true
end

--- Возвращает имя хоста сервера.
--- @return string result Имя хоста.
function get_server_name()
    return hostname
end

--- Отправляет данные мониторинга на настроенные адреса.
--- @param content string Содержимое для отправки (JSON-строка).
--- @param feed string Тип фида (например, "channels", "analyze", "errors", "psi", "dvb").
--- @return boolean success Статус выполнения
--- @return string|nil result Сообщение об ошибке или nil
function send_monitor(content, feed)
    log_debug(COMPONENT_NAME, "Отправка данных монитора для фида '%s'. Содержимое: %s.", feed, content)
    local recipients = MONIT_ADDRESS[feed]
    if recipients and #recipients > 0 then
        local content_length = #content
        local common_headers = {
            "User-Agent: Astra v." .. astra_version,
            "Content-Type: application/json;charset=utf-8",
            "Content-Length: " .. content_length,
            "Connection: close",
        }


        for _, addr in ipairs(recipients) do
            local headers = shallow_table_copy(common_headers) -- Копируем общие заголовки
            http_request({
                host = addr.host,
                path = addr.path,
                method = "POST",
                content = content,
                port = addr.port,
                headers = headers,
                callback = function(s,r)
                    if not s then
                        log_error(COMPONENT_NAME, "HTTP-запрос не удался для фида '%s' к %s:%s%s: status=connection_error.", feed, addr.host, tostring(addr.port), addr.path)
                    elseif type(r) == "table" and r.code and r.code ~= 200 then
                        log_error(COMPONENT_NAME, "HTTP-запрос не удался для фида '%s' к %s:%s%s: status=%s.", feed, addr.host, tostring(addr.port), addr.path, r.code)
                    elseif type(r) == "string" then -- Если r - это строка с ошибкой
                        log_error(COMPONENT_NAME, "HTTP-запрос не удался для фида '%s' к %s:%s%s: error=%s.", feed, addr.host, tostring(addr.port), addr.path, r)
                    end
                end
            })
        end
        return true
    else
        local err = string_format("Для фида '%s' не настроены получатели. Пропуск отправки.", feed)
        log_info(COMPONENT_NAME, err)
        return false, err
    end
end

return {
    get_stream = get_stream,
    ratio = ratio,
    shallow_table_copy = shallow_table_copy,
    validate_monitor_param = validate_monitor_param,
    validate_monitor_name = validate_monitor_name,
    set_client_monitoring = set_client_monitoring,
    remove_client_monitoring = remove_client_monitoring,
    get_server_name = get_server_name,
    send_monitor = send_monitor,
}
