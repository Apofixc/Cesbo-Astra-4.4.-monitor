-- ===========================================================================
-- Модуль `config.monitor_config`
--
-- Содержит настраиваемые параметры, которые определяют поведение различных
-- компонентов системы мониторинга, таких как логирование и параметры
-- мониторов каналов.
-- ===========================================================================

-- 1. Стандартные Lua функции
-- Нет стандартных Lua функций в этом модуле

-- 2. Функции из ModuleManager.get_module()
-- Нет функций из ModuleManager.get_module() в этом модуле

-- 3. Глобальные зависимости Astra из ModuleManager.get_global_dependency()
-- Нет глобальных зависимостей Astra в этом модуле

-- 4. Константы и конфигурации
--- @class MonitorConfig
local MonitorConfig = {}

-- 5. Инициализация объектов из загруженных модулей
-- Нет объектов для инициализации в этом модуле

--- Настройки логирования.
--- Определяет уровень детализации сообщений, выводимых в лог.
--- Доступные уровни: "DEBUG", "INFO", "WARN", "ERROR", "NONE".
--- @type string
MonitorConfig.LogLevel = "WARN" -- Изменено на "WARN" для уменьшения объема логов в продакшене.

--- Настройки монитора канала.
--- Эти параметры используются для конфигурирования поведения ChannelMonitor.
--- @type number
MonitorConfig.ChannelMonitorLimit = 50 -- Максимальное количество одновременно активных мониторов каналов.
--- @type number
MonitorConfig.DvbMonitorLimit = 20  -- Максимальное количество одновременно активных DVB-мониторов (примерное значение).
--- @type number
MonitorConfig.MaxMonitorNameLength = 64 -- Максимальная длина имени монитора.
--- @type number
MonitorConfig.MinRate = 0.001       -- Минимальное допустимое значение погрешности при сравнении битрейта.
--- @type number
MonitorConfig.MaxRate = 0.3         -- Максимальное допустимое значение погрешности при сравнении битрейта.
--- @type number
MonitorConfig.MinTimeCheck = 0      -- Минимальный интервал (в секундах) между проверками данных монитором.
--- @type number
MonitorConfig.MaxTimeCheck = 300    -- Максимальный интервал (в секундах) между проверками данных монитором.
--- @type number
MonitorConfig.MinMethodComparison = 1 -- Минимальное значение для метода сравнения состояния потока.
--- @type number
MonitorConfig.MaxMethodComparison = 4 -- Максимальное значение для метода сравнения состояния потока.

--- Схема валидации для параметров мониторов.
--- Определяет правила валидации, значения по умолчанию и типы для каждого параметра.
--- @type table<string, table>
MonitorConfig.ValidationSchema = {
    channel_rate = {
        type = "number",
        min = MonitorConfig.MinRate,
        max = MonitorConfig.MaxRate,
        default = 0.035
    },
    channel_time_check = {
        type = "number",
        min = MonitorConfig.MinTimeCheck,
        max = MonitorConfig.MaxTimeCheck,
        default = 0
    },
    channel_analyze = {
        type = "boolean",
        default = false
    },
    channel_method_comparison = {
        type = "number",
        min = MonitorConfig.MinMethodComparison,
        max = MonitorConfig.MaxMethodComparison,
        default = 3
    },
    dvb_time_check = {
        type = "number",
        min = MonitorConfig.MinTimeCheck,
        max = MonitorConfig.MaxTimeCheck,
        default = 10
    },
    dvb_rate = {
        type = "number",
        min = 0.001,
        max = 1,
        default = 0.015
    },
    dvb_method_comparison = {
        type = "number",
        min = 1,
        max = 3,
        default = 3
    }
}

return MonitorConfig
