-- Скрипт для сканирования DVB-C частот и сбора SID программ
package.path = package.path .. ";;/opt/astra/lib-monitor/?.lua;;/opt/astra/lib-monitor/http/?.lua;;/opt/astra/lib-monitor/config/?.lua;;"

local ModuleManager = require "init_monitor"
local Logger = ModuleManager.get_module("logger")
local dvb_tune = ModuleManager.get_global_dependency("dvb_tune")
local analyze = ModuleManager.get_global_dependency("analyze")
local timer = ModuleManager.get_global_dependency("timer")

log.set({ debug = true, stdout = true })

local frequencies = { 506, 514, 522, 530 } -- Пример сетки частот
local current_idx = 1
local results = {}

local function scan_next()
    if current_idx > #frequencies then
        print("\n=== SCAN COMPLETED ===")
        for freq, data in pairs(results) do
            print(string.format("Frequency: %d MHz, Programs: %d", freq, #data.programs))
            for _, p in ipairs(data.programs) do
                print(string.format("  - PNR: %d, Name: %s", p.pnr, p.name or "Unknown"))
            end
        end
        os.exit(0)
        return
    end

    local freq = frequencies[current_idx]
    print(string.format("\n--- Scanning %d MHz ---", freq))

    local tuner = dvb_tune({
        adapter = 0,
        type = "C",
        frequency = freq,
        symbolrate = 6900,
        modulation = "QAM256",
    })

    if not tuner then
        print("Failed to open tuner")
        current_idx = current_idx + 1
        scan_next()
        return
    end

    local programs = {}
    local analyzer = analyze({
        name = "scan_" .. freq,
        upstream = tuner:stream(),
        callback = function(data)
            if data.psi and data.psi == "SDT" and data.programs then
                for pnr, pdata in pairs(data.programs) do
                    table.insert(programs, { pnr = pnr, name = pdata.name })
                end
            end
        end
    })

    -- Ждем 5 секунд на каждой частоте для сбора SDT
    timer({
        interval = 5,
        callback = function(t)
            t:close()
            analyzer = nil
            tuner:close()
            results[freq] = { programs = programs }
            current_idx = current_idx + 1
            scan_next()
        end
    })
end

scan_next()
