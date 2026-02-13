--- @class Profiler
--- @field start_time number
--- @field start_memory number
--- @field results table
local Profiler = {}
Profiler.__index = Profiler

--- @return Profiler
function Profiler:new()
    local self = setmetatable({}, Profiler)
    self.start_time = 0
    self.start_memory = 0
    self.results = {}
    return self
end

function Profiler:start()
    self.start_time = os.clock()
    self.start_memory = collectgarbage("count")
end

--- @param name string
function Profiler:stop(name)
    local end_time = os.clock()
    local end_memory = collectgarbage("count")
    self.results[name] = {
        time = end_time - self.start_time,
        memory = end_memory - self.start_memory
    }
end

function Profiler:report()
    print("--- Отчет профилировщика ---")
    for name, data in pairs(self.results) do
        print(string.format("  %s: Время: %.4f с, Память: %.2f КБ", name, data.time, data.memory))
    end
    print("---------------------------")
end

return Profiler
