-- 1. Настройка путей
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;"

-- 2. Инициализация библиотеки мониторинга
local ModuleManager = require "init_monitor"
if not ModuleManager then
    print("Ошибка инициализации lib-monitor")
    astra.exit()
end

-- 3. Получение зависимостей
local DvbTuner = ModuleManager.get_module("dvb_tuner")
local json_lib = ModuleManager.get_global_dependency("json.encode")

-- 4. Создаем "фейковый" адаптер на базе HTTP потока для теста логики
local input_url = "http://31.130.202.110/httpts/tv3by/avchigh.ts"
local mock_adapter = make_stream({
    name = "MockAdapter",
    input = { input_url },
    output = { "file:///dev/null" }
})

-- 5. Создаем экземпляр DvbTuner и подменяем его инстанс нашим фейком
local tuner = DvbTuner.new({
    name_adapter = "TestAdapter",
    type = "C",
    frequency = 506
})

-- Имитируем запуск: подставляем реальный поток Astra в поле instance
-- mock_adapter это channel_data, mock_adapter.input[1].input это сам модуль
tuner.instance = mock_adapter.input[1].input

log.info("--- Запуск on-demand сбора PSI таблиц с адаптера...")

local is_finished = false

-- 6. Вызываем новый метод update_psi
local success = tuner:update_psi(function(collected)
    log.info("--- Callback update_psi вызван!")
    
    if collected.pat or collected.pmt then
        log.info("--- Таблицы успешно собраны асинхронно!")
        log.info("--- Содержимое кэша через get_psi():")
        local cache = tuner:get_psi()
        if cache.pat then log.info("    [OK] PAT найден") end
        if cache.pmt then log.info("    [OK] PMT найден") end
        
        -- Сохраняем результат
        local f = io.open("/opt/dvb_psi_ondemand.json", "w")
        if f then
            f:write(json_lib(cache))
            f:close()
            log.info("--- Данные сохранены в /opt/dvb_psi_ondemand.json")
        end
        
        is_finished = true
    else
        log.error("--- Таблицы не собраны")
    end
end, 5) -- Ждем 5 секунд

if not success then
    log.error("--- Не удалось запустить update_psi")
    astra.exit()
end

-- 7. Проверка удаления анализатора
timer({
    interval = 7,
    callback = function()
        if tuner._temp_analyzer == nil then
            log.info("--- [OK] Временный анализатор успешно удален после сбора")
        else
            log.error("--- [FAIL] Временный анализатор все еще висит в памяти")
        end
        
        log.info("--- Тест завершен.")
        astra.exit()
    end
})

-- Таймаут безопасности
timer({
    interval = 20,
    callback = function()
        if not is_finished then
            log.error("--- Тайм-аут теста")
            astra.exit()
        end
    end
})
