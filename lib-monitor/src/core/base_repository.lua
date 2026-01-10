--- @class BaseRepository
--- @field protected monitors table<string, any> Таблица активных объектов
--- @field protected classes table<string, table> Таблица классов мониторов для автовосстановления
--- @field protected count_active number Количество активных объектов
--- @field protected component_name string Имя компонента для логирования
local BaseRepository = {}
BaseRepository.__index = BaseRepository

-- 1. Стандартные Lua функции
local os_time = os.time
local pairs = pairs
local ipairs = ipairs
local tostring = tostring
local setmetatable = setmetatable

-- 2. Функции из ModuleManager.get_module()
local Logger = ModuleManager.get_module("logger")
local BaseMonitor = ModuleManager.get_module("core.base_monitor")

--- Конструктор базового репозитория
--- @param component_name string Имя компонента для логирования
--- @return BaseRepository
function BaseRepository.new(component_name)
    local self = setmetatable({}, BaseRepository)
    self.monitors = {}
    self.classes = {}
    self.count_active = 0
    self.component_name = component_name or "BaseRepository"
    return self
end

--- Регистрирует новый объект в репозитории
--- @param name string Имя объекта
--- @param instance any Экземпляр объекта
--- @param class? table Класс (мета-таблица) объекта для автовосстановления
function BaseRepository:register(name, instance, class)
    if self.monitors[name] then
        Logger.warn(self.component_name, "Объект '%s' уже зарегистрирован. Перезапись.", name)
    else
        self.count_active = self.count_active + 1
    end
    self.monitors[name] = instance
    if class then
        self.classes[name] = class
    end
    Logger.debug(self.component_name, "Объект '%s' зарегистрирован.", name)
end

--- Удаляет объект из репозитория и останавливает его
--- @param name string Имя объекта
--- @param force boolean Принудительная остановка
--- @return table|nil Оригинальная конфигурация при успехе, иначе nil
function BaseRepository:unregister(name, force)
    local instance = self.monitors[name]
    if not instance then
        Logger.error(self.component_name, "unregister: объект '%s' не найден", name)
        return nil
    end

    -- Все мониторы наследуются от BaseMonitor и имеют метод destroy
    local config = instance.destroy and instance:destroy(force)
    if config then
        self.monitors[name] = nil
        self.count_active = self.count_active - 1
        Logger.debug(self.component_name, "Объект '%s' удален и остановлен (принудительно: %s).", name, tostring(force))
        return config
    end

    Logger.error(self.component_name, "unregister: не удалось уничтожить объект '%s'", name)
    return nil
end

--- Выполняет автоматическое восстановление зависших мониторов.
--- Монитор считается зависшим, если он в состоянии RUNNING, но не обновлял данные более 5 минут.
--- @return number recovered Количество восстановленных мониторов
--- @return number failed Количество неудачных попыток
function BaseRepository:auto_recover()
    local recovered = 0
    local failed = 0
    local now = os_time()

    -- Создаем список имен для итерации, так как unregister/register меняют таблицу
    local names = {}
    for name in pairs(self.monitors) do
        names[#names + 1] = name
    end

    for _, name in ipairs(names) do
        local monitor = self.monitors[name]
        local class = self.classes[name]

        if monitor and monitor.health_check and class then
            local health = monitor:health_check()

            -- Проверка на "зависшие" мониторы (RUNNING, но нет обновлений > 300 сек)
            if health.state == BaseMonitor.STATE.RUNNING and
               now - (health.last_update or 0) > 300 then

                Logger.warn(self.component_name, "Попытка восстановления зависшего монитора: %s", name)

                -- 1. Останавливаем и получаем конфиг
                local config = self:unregister(name, true)

                -- 2. Пытаемся создать и запустить новый экземпляр
                if config and class.new then
                    local new_monitor = class.new(config)
                    if new_monitor and new_monitor.start and new_monitor:start() then
                        self:register(name, new_monitor, class)
                        recovered = recovered + 1
                        Logger.info(self.component_name, "Монитор %s успешно восстановлен", name)
                    else
                        failed = failed + 1
                        Logger.error(self.component_name, "Не удалось перезапустить монитор %s при восстановлении", name)
                    end
                else
                    failed = failed + 1
                    Logger.error(self.component_name, "Не удалось восстановить монитор %s: отсутствует конфиг или класс", name)
                end
            end
        end
    end

    return recovered, failed
end

--- Находит объект по имени
--- @param name string Имя объекта
--- @return any|nil Экземпляр объекта или nil
function BaseRepository:find(name)
    return self.monitors[name]
end

--- Возвращает список всех объектов
--- @return table<string, any> Таблица объектов
function BaseRepository:get_all()
    return self.monitors
end

--- Возвращает количество активных объектов
--- @return number Количество объектов
function BaseRepository:count()
    return self.count_active
end

--- Останавливает и удаляет все объекты в репозитории.
--- Используется при завершении работы системы.
function BaseRepository:shutdown()
    Logger.info(self.component_name, "Остановка репозитория: завершение работы %d мониторов", self.count_active)
    local names = {}
    for name in pairs(self.monitors) do
        table.insert(names, name)
    end

    for _, name in ipairs(names) do
        self:unregister(name, true)
    end
end

return BaseRepository
