--- @class Mock
--- @field original_env table
--- @field mocks table<string, any>
--- @field upvalue_mocks table<function, table<number, any>>
local Mock = {}
Mock.__index = Mock

--- @return Mock
function Mock:new()
    local self = setmetatable({}, Mock)
    self.original_env = {}
    self.mocks = {}
    self.upvalue_mocks = {}
    return self
end

--- Вспомогательная функция для поиска upvalue по имени.
--- @private
--- @param func function Функция, в которой ищем upvalue.
--- @param target_name string Имя upvalue для поиска.
--- @return number|nil index Индекс upvalue, если найдено.
--- @return any|nil value Текущее значение upvalue, если найдено.
local function find_upvalue(func, target_name)
    local i = 1
    while true do
        local name, val = debug.getupvalue(func, i)
        if not name then break end
        if name == target_name then return i, val end
        i = i + 1
    end
    return nil, nil
end

--- Мокирует глобальную переменную.
--- @param name string Имя глобальной переменной.
--- @param value any Новое значение.
function Mock:mock_global(name, value)
    self.original_env[name] = _G[name]
    if type(_G[name]) == "table" and type(value) == "table" then
        -- Если оригинальное и новое значение - таблицы, объединяем их
        local new_table = {}
        for k, v in pairs(_G[name]) do
            new_table[k] = v
        end
        for k, v in pairs(value) do
            new_table[k] = v
        end
        _G[name] = new_table
    else
        _G[name] = value
    end
    self.mocks[name] = value
end

--- Мокирует поле в таблице.
--- @param table table Таблица, в которой мокируется поле.
--- @param name string Имя поля.
--- @param value any Новое значение.
function Mock:mock_field(table, name, value)
    self.original_env[table] = self.original_env[table] or {}
    self.original_env[table][name] = table[name]
    table[name] = value
    self.mocks[table] = self.mocks[table] or {}
    self.mocks[table][name] = value
end

--- Мокирует локальную/приватную переменную (upvalue) в функции.
--- @param func function Функция, содержащая upvalue.
--- @param name string Имя upvalue для мокирования.
--- @param value any Новое значение.
--- @return boolean success Успешно ли замокировано.
function Mock:mock_upvalue(func, name, value)
    local idx, original_value = find_upvalue(func, name)
    if idx then
        self.upvalue_mocks[func] = self.upvalue_mocks[func] or {}
        self.upvalue_mocks[func][idx] = original_value -- Сохраняем оригинальное значение по индексу
        debug.setupvalue(func, idx, value)
        return true
    end
    return false
end

--- Мокирует локальную/приватную переменную (upvalue) во всех функциях модуля.
--- @param module_table table Таблица, представляющая модуль (например, `_G` или возвращаемое значение `require`).
--- @param upvalue_name string Имя upvalue для мокирования.
--- @param new_value any Новое значение.
--- @return boolean success Было ли замокировано хотя бы одно upvalue.
function Mock:mock_module_upvalue(module_table, upvalue_name, new_value)
    local mocked_any = false
    local original_upvalue_value = nil
    local functions_to_patch = {}

    -- Сначала собираем все функции, которые используют данный upvalue, и находим оригинальное значение
    for _, func in pairs(module_table) do
        if type(func) == "function" then
            local idx, val = find_upvalue(func, upvalue_name)
            if idx then
                table.insert(functions_to_patch, {func = func, idx = idx})
                if original_upvalue_value == nil then
                    original_upvalue_value = val -- Сохраняем первое найденное оригинальное значение
                end
            end
        end
    end

    -- Теперь мокируем upvalue во всех найденных функциях, используя одно оригинальное значение для восстановления
    if original_upvalue_value ~= nil then
        for _, item in ipairs(functions_to_patch) do
            local func = item.func
            local idx = item.idx

            self.upvalue_mocks[func] = self.upvalue_mocks[func] or {}
            -- Сохраняем оригинальное значение upvalue, которое было до начала мокирования
            self.upvalue_mocks[func][idx] = original_upvalue_value
            debug.setupvalue(func, idx, new_value)
            mocked_any = true
        end
    end

    return mocked_any
end

--- Восстанавливает все замоканные значения.
function Mock:restore()
    -- Восстановление глобальных переменных и полей таблиц
    for name, original_value in pairs(self.original_env) do
        if type(name) == "string" then
            _G[name] = original_value
        elseif type(name) == "table" then
            for field_name, field_original_value in pairs(original_value) do
                name[field_name] = field_original_value
            end
        end
    end
    self.original_env = {}
    self.mocks = {}

    -- Восстановление upvalue
    for func, original_upvalues in pairs(self.upvalue_mocks) do
        for idx, original_value in pairs(original_upvalues) do
            debug.setupvalue(func, idx, original_value)
        end
    end
    self.upvalue_mocks = {}
end

--- Возвращает таблицу всех upvalue для данной функции.
--- @param func function Функция для инспекции.
--- @return table<string, any> Таблица upvalue (имя -> значение).
function Mock:get_function_upvalues(func)
    local upvalues = {}
    local i = 1
    while true do
        local name, val = debug.getupvalue(func, i)
        if not name then break end
        upvalues[name] = val
        i = i + 1
    end
    return upvalues
end

--- Возвращает таблицу всех upvalue для всех функций в модуле.
--- @param module_table table Таблица, представляющая модуль.
--- @return table<function, table<string, any>> Таблица, где ключи - функции, значения - их upvalue.
function Mock:get_module_upvalues(module_table)
    local module_upvalues = {}
    for _, func in pairs(module_table) do
        if type(func) == "function" then
            module_upvalues[func] = self:get_function_upvalues(func)
        end
    end
    return module_upvalues
end

return Mock
