-- 1. Настройка путей
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;"

-- 2. Инициализация библиотеки мониторинга
local ModuleManager = require "init_monitor"
if not ModuleManager then
    print("Ошибка инициализации lib-monitor")
    astra.exit()
end

-- 3. Получение зависимостей
local json_lib = ModuleManager.get_global_dependency("json.encode")
local ChannelMonitor = ModuleManager.get_module("channel_monitor")
local ChannelStorage = ModuleManager.get_module("channel_storage")

-- 4. Создание входного потока через библиотеку
local input_url = "http://31.130.202.110/httpts/tv3by/avchigh.ts"
local stream_data = make_stream({
    name = "TestStream",
    input = { input_url },
    output = { "file:///dev/null" },
    monitor = {
        join_pid = true,
        rate_stat = true,
        analyze = true,
        method_comparison = 1
    }
})

if not stream_data then
    log.error("--- Не удалось создать поток")
    astra.exit()
end

-- 5. Получаем инстанс монитора из хранилища
local monitor = ChannelStorage.find("TestStream")
if not monitor then
    log.error("--- Монитор не найден в хранилище")
    astra.exit()
end

local is_finished = false

-- 6. Периодическая проверка собранных данных
timer({
    interval = 1,
    callback = function()
        if is_finished then return end
        
        local psi_cache = monitor:get_psi()
        if psi_cache then
            local pat = psi_cache["pat"]
            local pmt = psi_cache["pmt"]
            
            if pat and pmt then
                log.info("--- Все необходимые таблицы (PAT, PMT) найдены в кэше монитора!")
                
                local f = io.open("/opt/psi_tables.json", "w")
                if f then
                    f:write(json_lib(psi_cache))
                    f:close()
                    log.info("--- Таблицы сохранены в /opt/psi_tables.json")
                end
                
                log.info("--- Удаляем поток и монитор...")
                kill_stream("TestStream")
                is_finished = true
                
                timer({
                    interval = 1,
                    callback = function()
                        log.info("--- Тест завершен успешно.")
                        astra.exit()
                    end
                })
            else
                log.info("--- Ожидание таблиц... (PAT: " .. (pat and "OK" or "нет") .. ", PMT: " .. (pmt and "OK" or "нет") .. ")")
            end
        end
    end
})

log.info("--- Тест запущен. Ожидание сбора PSI данных...")

-- Таймаут
timer({
    interval = 30,
    callback = function()
        if not is_finished then
            log.error("--- Тайм-аут теста (30 сек)")
            astra.exit()
        end
    end
})
