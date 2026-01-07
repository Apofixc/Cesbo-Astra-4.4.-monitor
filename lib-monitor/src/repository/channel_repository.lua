-- 1. Стандартные Lua функции
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local table_insert = table.insert

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local BaseRepository = ModuleManager.get_module("core.base_repository")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
local channel_list = ModuleManager.get_global_dependency("channel_list")

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelRepository"

-- 5. Инициализация объектов из загруженных модулей
--- @class ChannelRepository : BaseRepository
local ChannelRepository = BaseRepository.new(COMPONENT_NAME)

--- Останавливает все каналы, использующие указанный адаптер.
--- @param adapter_name string Имя адаптера
--- @return table Список сохраненных конфигураций каналов
function ChannelRepository:stop_dependent_channels(adapter_name)
    local Channel = ModuleManager.get_module("channel")
    local saved_configs = {}
    if not Channel then return saved_configs end

    local dependent_channels = self:find_by_adapter(adapter_name)
    for name, _ in pairs(dependent_channels) do
        local ch_config = Channel.kill_stream(name)
        if ch_config then
            table_insert(saved_configs, ch_config)
        end
    end
    return saved_configs
end

--- Запускает каналы на основе предоставленных конфигураций.
--- @param configs table Список конфигураций каналов
function ChannelRepository:start_dependent_channels(configs)
    if not configs or type(configs) ~= "table" then return end
    local Channel = ModuleManager.get_module("channel")
    if not Channel then return end

    for _, conf in ipairs(configs) do
        Channel.make_stream(conf)
    end
end

--- Находит все каналы в системе Astra, использующие указанный DVB-адаптер
--- @param adapter_name string Имя адаптера (например, "0" или "0.1")
--- @return table<string, table> Список найденных каналов (имя -> ch_data)
function ChannelRepository:find_by_adapter(adapter_name)
    local result = {}    
    
    if not channel_list then
        Logger.error(COMPONENT_NAME, "find_by_adapter: channel_list dependency not found")
        return result
    end

    local target_adapter = tostring(adapter_name)
    for _, ch_data in pairs(channel_list) do
        local inputs = ch_data.input
        if type(inputs) == "table" then
            for i = 1, #inputs do
                local input = inputs[i]
                -- В Astra ch_data.input[i] может быть строкой URL или таблицей с полем config
                local cfg
                if type(input) == "table" then
                    cfg = input.config
                elseif type(input) == "string" then
                    -- Если это строка, пробуем распарсить её (упрощенно для DVB)
                    if input:find("^dvb://") then
                        local addr = input:match("^dvb://([^#?]+)")
                        if addr == target_adapter then
                            local name = (type(ch_data.config) == "table") and ch_data.config.name
                            if name then result[name] = ch_data end
                            break
                        end
                    end
                end

                if cfg and cfg.format == "dvb" and tostring(cfg.addr) == target_adapter then
                    local name = (type(ch_data.config) == "table") and ch_data.config.name
                    if name then
                        result[name] = ch_data
                    end
                    break
                end
            end
        end
    end
    return result
end

return ChannelRepository
