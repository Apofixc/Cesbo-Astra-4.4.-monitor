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
	killall astra4.4.182
	;;
esac
exit 0

