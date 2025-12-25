-- ===========================================================================
-- Модуль `init_monitor`
--
-- Этот модуль является точкой входа для инициализации и загрузки всех
-- необходимых компонентов библиотеки `lib-monitor`. Он обеспечивает
-- подключение основных утилит, адаптеров, модулей каналов, HTTP-сервера
-- и диспетчеров мониторинга.
-- ===========================================================================

require "src.utils.utils"
require "src.adapters.adapter"
require "src.channel.channel"
require "http.http_server"
require "src.dispatchers.channel_monitor_dispatcher"
require "src.dispatchers.dvb_monitor_dispatcher"
