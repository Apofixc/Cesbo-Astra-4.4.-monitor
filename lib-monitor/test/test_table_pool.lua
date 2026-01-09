-- Тест для TablePool: проверка глубокой очистки

-- Mock ModuleManager
_G.ModuleManager = {
    get_module = function(name)
        return {
            info = function() end,
            error = function() end,
            debug = function() end,
            warn = function() end
        }
    end
}

local TablePool = require "src.utils.table_pool"

local function test_deep_clean()
    print("--- Testing TablePool Deep Clean ---")
    local t = TablePool.get("test")
    t.inner = { a = 1, b = { c = 2 } }
    t.val = 10
    
    print("Before release: t.inner.b.c =", t.inner and t.inner.b and t.inner.b.c)
    
    TablePool.release(t, "test", true) -- Глубокая очистка
    
    local t2 = TablePool.get("test")
    print("After release (deep): t2.inner =", t2.inner)
    print("After release (deep): t2.val =", t2.val)
    
    if t2.inner == nil and t2.val == nil then
        print("SUCCESS: Deep clean works")
    else
        print("FAILED: Deep clean failed")
    end
end

local function test_shallow_clean()
    print("\n--- Testing TablePool Shallow Clean ---")
    local t = TablePool.get("test_shallow")
    t.inner = { a = 1 }
    
    TablePool.release(t, "test_shallow", false) -- Поверхностная очистка
    
    local t2 = TablePool.get("test_shallow")
    print("After release (shallow): t2.inner =", t2.inner)
    
    if t2.inner == nil then
        print("SUCCESS: Shallow clean works")
    else
        print("FAILED: Shallow clean failed")
    end
end

test_deep_clean()
test_shallow_clean()
