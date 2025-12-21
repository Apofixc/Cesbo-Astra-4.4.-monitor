-- ===========================================================================
-- Модуль `init_monitor`
--
-- Этот модуль является точкой входа для инициализации и загрузки всех
-- необходимых компонентов библиотеки `lib-monitor`. Он обеспечивает
-- подключение основных утилит, адаптеров, модулей каналов, HTTP-сервера
-- и диспетчеров мониторинга.
-- ===========================================================================

require "utils.utils"
require "adapters.adapter"
require "channel.channel"
require "http.http_server"
require "dispatcher.channel_monitor_manager"
require "dispatcher.dvb_monitor_manager"
require "dispatcher.resource_monitor_manager" -- Добавлено для загрузки менеджера ресурсов
