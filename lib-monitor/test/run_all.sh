#!/bin/bash
# run_all.sh — ПМИ 7.1: Unit -> Integration -> System с luacov
# Запуск: из корня Cesbo-Astra-4.4.-monitor или lib-monitor

set -e
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
LIB_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
ROOT_DIR="$(cd "$LIB_DIR/.." && pwd)"
ASTRA_BIN="${ROOT_DIR}/astra4.4.182"
RUN_TEST="${LIB_DIR}/test/run_test.lua"

if [ ! -f "$ASTRA_BIN" ]; then
    echo "Ошибка: astra4.4.182 не найден в $ROOT_DIR"
    exit 1
fi

echo "=== ПМИ: Полный прогон тестов (Unit -> Integration -> System) ==="
echo ""

"$ASTRA_BIN" "$RUN_TEST" unit integration system 2>&1
EXIT_CODE=$?

echo ""
if [ $EXIT_CODE -eq 0 ]; then
    echo "=== Все тесты пройдены ==="
else
    echo "=== Есть провалы. Код выхода: $EXIT_CODE ==="
fi

exit $EXIT_CODE
