-- Тест новой системы логирования и контекстной обработки ошибок

-- Эмуляция ModuleManager для теста
local mock_modules = {}
_G.ModuleManager = {
    get_module = function(name)
        return mock_modules[name]
    end,
    get_global_dependency = function(name)
        if name == "log" then
            return {
                info = function(msg) print("ASTRA INFO: " .. msg) end,
                error = function(msg) print("ASTRA ERROR: " .. msg) end,
                debug = function(msg) print("ASTRA DEBUG: " .. msg) end,
                warn = function(msg) print("ASTRA WARN: " .. msg) end,
            }
        end
    end
}

-- Загружаем логгер
local Logger = dofile("astra/lib-monitor/src/utils/logger.lua")
mock_modules["logger"] = Logger

-- Тестовая функция бизнес-логики
local function business_logic(fail, message)
    if fail then
        Logger.error("TestComp", message or "Something went wrong")
        return false
    end
    return true, "Success data"
end

print("--- Test 1: Normal call (no context) ---")
local success, result = business_logic(true, "Error without context")
print("Success:", success, "Result:", result)

print("\n--- Test 2: Call with context (failure) ---")
local success, result_or_err = Logger.with_error(business_logic, true, "Error WITH context")
print("Success:", success)
print("Result/Error:", result_or_err)

print("\n--- Test 3: Call with context (success) ---")
local success, result_or_err = Logger.with_error(business_logic, false)
print("Success:", success)
print("Result/Error:", result_or_err)

print("\n--- Test 4: Nested context ---")
local success, err = Logger.with_error(function()
    return Logger.with_error(business_logic, true, "Nested error")
end)
print("Success:", success)
print("Error:", err)

print("\n--- Test 5: Runtime error (crash) ---")
local success, err = Logger.with_error(function()
    error("Boom!")
end)
print("Success:", success)
print("Error:", err)
