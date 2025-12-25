-- ===========================================================================
-- Модуль `init_monitor`
--
-- Этот модуль является точкой входа для инициализации и загрузки всех
-- необходимых компонентов библиотеки `lib-monitor`. Он обеспечивает
-- подключение основных утилит, адаптеров, модулей каналов, HTTP-сервера
-- и диспетчеров мониторинга.
-- ===========================================================================

require "lib-monitor.src.utils.logger"
require "lib-monitor.src.utils.utils"
require "lib-monitor.src.adapters.adapter"
require "lib-monitor.src.channel.channel"
require "lib-monitor.http.http_server"
require "lib-monitor.src.dispatchers.channel_monitor_dispatcher"
require "lib-monitor.src.dispatchers.dvb_monitor_dispatcher"
