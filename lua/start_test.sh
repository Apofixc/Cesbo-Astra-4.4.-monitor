#!/bin/bash

case "$1" in
    start)
	/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lua/test1.lua &
	/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lua/test2.lua &
	/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lua/test3.lua &
	/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lua/tv2.lua &
	/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lua/tv3.lua &
	/opt/Cesbo-Astra-4.4.-monitor/astra4.4.182 /opt/Cesbo-Astra-4.4.-monitor/lua/varjag.lua &
	;;
    stop)
	kill `cat /var/run/test1.pid`
	kill `cat /var/run/test2.pid`
	kill `cat /var/run/test3.pid`
	kill `cat /var/run/tv2.pid`
	kill `cat /var/run/tv3.pid`
	kill `cat /var/run/varjag.pid`
	;;
esac
exit 0

