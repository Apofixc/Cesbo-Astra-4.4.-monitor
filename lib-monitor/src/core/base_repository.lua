--- @class BaseRepository
--- @field protected monitors table<string, any> Таблица активных объектов
--- @field protected count_active number Количество активных объектов
--- @field protected component_name string Имя компонента для логирования
local BaseRepository = {}
BaseRepository.__index = BaseRepository

-- 1. Стандартные Lua функции
local pairs = pairs
local tostring = tostring
local setmetatable = setmetatable

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")

--- Конструктор базового репозитория
--- @param component_name string Имя компонента для логирования
--- @return BaseRepository
function BaseRepository.new(component_name)
    local self = setmetatable({}, BaseRepository)
    self.monitors = {}
    self.count_active = 0
    self.component_name = component_name or "BaseRepository"
    return self
end

--- Регистрирует новый объект в репозитории
--- @param name string Имя объекта
--- @param instance any Экземпляр объекта
function BaseRepository:register(name, instance)
    if self.monitors[name] then
        Logger.warn(self.component_name, "Объект '%s' уже зарегистрирован. Перезапись.", name)
    else
        self.count_active = self.count_active + 1
    end
    self.monitors[name] = instance
    Logger.debug(self.component_name, "Объект '%s' зарегистрирован.", name)
end

--- Удаляет объект из репозитория и останавливает его
--- @param name string Имя объекта
--- @param force boolean Принудительная остановка
--- @return table|nil Оригинальная конфигурация при успехе, иначе nil
function BaseRepository:unregister(name, force)
    local instance = self.monitors[name]
    if not instance then
        Logger.error(self.component_name, "unregister: Объект '%s' не найден", name)
        return nil
    end

    -- Все мониторы наследуются от BaseMonitor и имеют метод destroy
    local config = instance.destroy and instance:destroy(force)
    if config then
        self.monitors[name] = nil
        self.count_active = self.count_active - 1
        Logger.debug(self.component_name, "Объект '%s' удален и остановлен (force: %s).", name, tostring(force))
        return config
    end

    Logger.error(self.component_name, "unregister: не удалось уничтожить объект '%s'", name)
    return nil
end

--- Находит объект по имени
--- @param name string Имя объекта
--- @return any|nil Экземпляр объекта или nil
function BaseRepository:find(name)
    if not self or not self.monitors then return nil end
    return self.monitors[name]
end

--- Возвращает список всех объектов
--- @return table<string, any> Таблица объектов
function BaseRepository:get_all()
    if not self or not self.monitors then return {} end
    return self.monitors
end

--- Возвращает количество активных объектов
--- @return number Количество объектов
function BaseRepository:count()
    if not self then return 0 end
    return self.count_active or 0
end

return BaseRepository
