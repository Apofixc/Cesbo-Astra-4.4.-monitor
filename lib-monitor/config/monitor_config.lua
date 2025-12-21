-- ===========================================================================
-- Конфигурация мониторинга для системы Astra.
-- Этот файл содержит настраиваемые параметры, которые определяют поведение
-- различных компонентов системы мониторинга, таких как логирование и
-- параметры мониторов каналов.
-- ===========================================================================

local MonitorConfig = {}

--- Настройки логирования.
-- Определяет уровень детализации сообщений, выводимых в лог.
-- Доступные уровни: "DEBUG", "INFO", "WARN", "ERROR", "NONE".
MonitorConfig.LogLevel = "DEBUG" -- Изменено на "WARN" для уменьшения объема логов в продакшене.

--- Настройки монитора канала.
-- Эти параметры используются для конфигурирования поведения ChannelMonitor.
MonitorConfig.ChannelMonitorLimit = 50 -- Максимальное количество одновременно активных мониторов каналов.
MonitorConfig.DvbMonitorLimit = 20  -- Максимальное количество одновременно активных DVB-мониторов (примерное значение).
MonitorConfig.MaxMonitorNameLength = 64 -- Максимальная длина имени монитора.
MonitorConfig.MinRate = 0.001       -- Минимальное допустимое значение погрешности при сравнении битрейта.
MonitorConfig.MaxRate = 0.3         -- Максимальное допустимое значение погрешности при сравнении битрейта.
MonitorConfig.MinTimeCheck = 0      -- Минимальный интервал (в секундах) между проверками данных монитором.
MonitorConfig.MaxTimeCheck = 300    -- Максимальный интервал (в секундах) между проверками данных монитором.
MonitorConfig.MinMethodComparison = 1 -- Минимальное значение для метода сравнения состояния потока.
MonitorConfig.MaxMethodComparison = 4 -- Максимальное значение для метода сравнения состояния потока.

--- Схема валидации для параметров мониторов.
-- Определяет правила валидации, значения по умолчанию и типы для каждого параметра.
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
