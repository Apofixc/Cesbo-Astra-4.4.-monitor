-- ===========================================================================
-- Модуль `init_monitor`
--
-- Этот модуль является точкой входа для инициализации и загрузки всех
-- необходимых компонентов библиотеки `lib-monitor`. Он обеспечивает
-- подключение основных утилит, адаптеров, модулей каналов, HTTP-сервера
-- и диспетчеров мониторинга.
-- ===========================================================================

local Logger = require "src.utils.logger" -- Загружаем Logger первым для возможности логирования ошибок инициализации
local InitChecker = require "src.init_checker" -- Загружаем InitChecker для проверки зависимостей

local success, errors = InitChecker.check_dependencies()

if not success then
    for _, err_msg in ipairs(errors) do
        Logger.error("InitMonitor", err_msg)
    end
    error("Failed to initialize lib-monitor due to missing dependencies.")
end

-- Загружаем остальные модули только после успешной проверки зависимостей
require "src.utils.utils"
require "src.adapters.adapter"
require "src.channel.channel"
require "http.http_server"
require "src.dispatchers.channel_monitor_dispatcher"
require "src.dispatchers.dvb_monitor_dispatcher"
