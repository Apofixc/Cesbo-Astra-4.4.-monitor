-- 1. Стандартные Lua функции
local pairs = pairs
local tostring = tostring

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local BaseRepository = ModuleManager.get_module("core.base_repository")

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет прямых зависимостей

-- 4. Константы и конфигурации
local COMPONENT_NAME = "ChannelRepository"

-- 5. Инициализация объектов из загруженных модулей
--- @class ChannelRepository : BaseRepository
local ChannelRepository = BaseRepository.new(COMPONENT_NAME)

--- Находит все каналы в системе Astra, использующие указанный DVB-адаптер
--- @param adapter_name string Имя адаптера (например, "0" или "0.1")
--- @return table<string, table> Список найденных каналов (имя -> ch_data)
function ChannelRepository:find_by_adapter(adapter_name)
    local result = {}    
    local channel_list = ModuleManager.get_global_dependency("channel_list")
    
    if not channel_list then
        Logger.error(COMPONENT_NAME, "find_by_adapter: channel_list dependency not found")
        return result
    end

    local target_adapter = tostring(adapter_name)
    for _, ch_data in pairs(channel_list) do
        local inputs = ch_data.input
        if inputs then
            for i = 1, #inputs do
                local input = inputs[i]
                local cfg = input.config
                if cfg and cfg.format == "dvb" and tostring(cfg.addr) == target_adapter then
                    local name = ch_data.config and ch_data.config.name
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
