-- Тест для EventDispatcher: проверка пулинга событий

-- Mock dependencies
_G.ModuleManager = {
    get_module = function(name)
        if name == "logger" then
            return {
                info = function(...) print("[INFO]", ...) end,
                error = function(...) print("[ERROR]", ...) end,
                debug = function(...) print("[DEBUG]", ...) end,
                warn = function(...) print("[WARN]", ...) end
            }
        elseif name == "core.subscription_manager" then
            return {
                new = function()
                    return {
                        publish_event = function(self, event)
                            print("Processing event:", event.id, "type:", event.type)
                        end,
                        match = function() return true end
                    }
                end
            }
        elseif name == "utils.table_pool" then
            return require "src.utils.table_pool"
        end
    end,
    get_global_dependency = function(name)
        if name == "timer" then
            return function(opts) return { close = function() end } end
        end
    end
}

local EventDispatcher = require "src.core.event_dispatcher"
local TablePool = require "src.utils.table_pool"

local function test_event_pooling()
    print("--- Testing EventDispatcher Pooling ---")
    local dispatcher = EventDispatcher.get_instance()
    
    -- Эмитируем событие
    local id1 = dispatcher:emit("test:event", { val = 1 })
    print("Emitted event 1, ID:", id1)
    
    -- Вручную вызываем обработку очереди (так как таймер в тестах не работает)
    dispatcher:process_queue()
    
    -- Проверяем статистику пула
    local stats = TablePool.get_stats()
    print("Pool stats after process:", "event =", stats.event)
    
    -- Эмитируем второе событие
    local id2 = dispatcher:emit("test:event", { val = 2 })
    print("Emitted event 2, ID:", id2)
    
    if stats.event and stats.event > 0 then
        print("SUCCESS: Event object was returned to pool")
    else
        print("FAILED: Event object was NOT returned to pool")
    end
end

test_event_pooling()
