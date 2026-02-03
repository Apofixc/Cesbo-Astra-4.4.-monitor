# Инструкция по использованию фреймворка `run_test`

Фреймворк `run_test` предназначен для автоматизированного тестирования Lua-кода, сбора метрик покрытия кода с помощью Luacov, а также для мокирования зависимостей и профилирования производительности.

## 1. Обзор `run_test.lua`

`run_test.lua` — это основной скрипт, который:
*   Настраивает среду выполнения Lua, включая `package.path` для доступа к тестовым утилитам и модулям `lib-monitor`.
*   Инициализирует Luacov для сбора статистики покрытия кода.
*   Рекурсивно ищет тестовые файлы (файлы, начинающиеся с `test_` и имеющие расширение `.lua`) в указанной директории (по умолчанию `/opt/astra/lib-monitor/test/unit`).
*   Запускает найденные тесты в изолированной среде.
*   Генерирует и выводит отчет Luacov после завершения всех тестов.
*   Возвращает код выхода `0` при успешном прохождении всех тестов и `1` в случае ошибок.

## 2. Запуск тестов

Для запуска тестов необходимо выполнить скрипт `run_test.lua` с помощью интерпретатора `astra` (версии 4.4.182 или 4.4.187cw), который находится в `/opt/astra/astra4.4.182` или `/opt/astra/astra4.4.187cw`.

Пример запуска:
```bash
/opt/astra/astra4.4.182 /opt/astra/lib-monitor/test/run_test.lua
```
или
```bash
/opt/astra/astra4.4.187cw /opt/astra/lib-monitor/test/run_test.lua
```

Скрипт автоматически найдет и запустит все тесты в директории `/opt/astra/lib-monitor/test/unit`.

## 3. Структура тестовых файлов

Тестовые файлы должны располагаться в директории `/opt/astra/lib-monitor/test/unit/` (или других поддиректориях внутри `/opt/astra/lib-monitor/test/`, если `run_test.lua` будет модифицирован для их поиска).
Имя каждого тестового файла должно начинаться с префикса `test_` (например, `test_monitor_config.lua`).

Внутри каждого тестового файла рекомендуется использовать `TestSuite` из `test_helper.lua` для организации тестов.

Пример структуры тестового файла:
```lua
local test_helper = require("test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert

local my_suite = TestSuite:new("MyModule Tests")

my_suite:add_test("test_something_is_true", function()
    Assert.is_true(true, "Это должно быть правдой")
end)

my_suite:add_test("test_addition_works", function()
    local result = 1 + 1
    Assert.are_equal(2, result, "1 + 1 должно быть 2")
end)

-- Запуск тестового набора
my_suite:run()
```

## 4. Использование `test_helper.lua`

`test_helper.lua` предоставляет базовые инструменты для написания тестов: `TestSuite` для группировки тестов и `Assert` для выполнения утверждений.

*   **`TestSuite`**
    *   `TestSuite:new(name)`: Создает новый тестовый набор с указанным именем.
    *   `suite:add_test(test_name, func)`: Добавляет тестовую функцию в набор. `test_name` — это строка, `func` — функция, содержащая логику теста и утверждения.
    *   `suite:run()`: Запускает все тесты в наборе. Выводит статус каждого теста (УСПЕХ/ОШИБКА).

*   **`Assert`**
    Предоставляет статические методы для проверки условий:
    *   `Assert.is_true(condition, message)`: Проверяет, что `condition` истинно.
    *   `Assert.is_false(condition, message)`: Проверяет, что `condition` ложно.
    *   `Assert.are_equal(expected, actual, message)`: Проверяет равенство `expected` и `actual`.
    *   `Assert.are_not_equal(expected, actual, message)`: Проверяет неравенство `expected` и `actual`.
    *   `Assert.is_nil(value, message)`: Проверяет, что `value` равно `nil`.
    *   `Assert.is_not_nil(value, message)`: Проверяет, что `value` не равно `nil`.
    *   `Assert.raises_error(func, message)`: Проверяет, что вызов `func` приводит к ошибке.

*   **`contains(tbl, val)`**: Вспомогательная функция для проверки наличия элемента `val` в таблице `tbl`. Возвращает `true`, если элемент найден, иначе `false`.

## 5. Использование `test_moc.lua`

`test_moc.lua` предоставляет класс `Mock` для изоляции тестируемого кода от его зависимостей путем мокирования глобальных переменных, полей таблиц и локальных переменных (upvalue).

*   **`Mock:new()`**: Создает новый экземпляр мока.
*   **`mock:mock_global(name, value)`**: Мокирует глобальную переменную `name` новым `value`.
*   **`mock:mock_field(table, name, value)`**: Мокирует поле `name` в таблице `table` новым `value`.
*   **`mock_upvalue(func, name, value)`**: Мокирует локальную переменную (upvalue) `name` внутри функции `func` новым `value`. Используется для приватных переменных модуля.
*   **`mock:mock_module_upvalue(module_table, upvalue_name, new_value)`**: Мокирует upvalue `upvalue_name` во всех функциях, содержащихся в `module_table` (например, в возвращаемой таблице модуля).
*   **`mock:restore()`**: Восстанавливает все замоканные значения до их оригинального состояния. **Крайне важно вызывать этот метод после каждого теста, использующего моки, чтобы избежать влияния на другие тесты.**
*   **`mock:get_function_upvalues(func)`**: Возвращает таблицу всех upvalue (локальных переменных) для данной функции `func` в формате `имя -> значение`.
*   **`mock:get_module_upvalues(module_table)`**: Возвращает таблицу всех upvalue для всех функций, содержащихся в `module_table` (например, в возвращаемой таблице модуля), где ключи — функции, значения — их upvalue.

Пример использования `Mock`:
```lua
local test_helper = require("test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("test_moc")

local my_suite = TestSuite:new("Mocking Tests")

-- Пример модуля с upvalue
local function create_test_module()
    local private_var = "original_private_value"
    local function get_private_var()
        return private_var
    end
    local function set_private_var(value)
        private_var = value
    end
    return {
        get_private_var = get_private_var,
        set_private_var = set_private_var
    }
end

my_suite:add_test("test_mock_global_log", function()
    local mock = Mock:new()
    local original_log_info = log.info -- Сохраняем оригинал для проверки

    mock:mock_global("log", { info = function(msg) print("MOCKED LOG: " .. msg) end })
    log.info("Hello from mock!")
    Assert.is_not_nil(log, "log не должен быть nil")
    Assert.is_not_nil(log.info, "log.info не должен быть nil")
    -- Здесь можно добавить проверку, что "MOCKED LOG: Hello from mock!" было выведено
    -- (что сложнее в автоматизированных тестах без перехвата stdout)

    mock:restore()
    Assert.are_equal(original_log_info, log.info, "log.info должен быть восстановлен")
end)

my_suite:add_test("test_mock_upvalue", function()
    local mock = Mock:new()
    local test_module = create_test_module()

    Assert.are_equal("original_private_value", test_module.get_private_var(), "До мокирования")

    -- Мокируем upvalue 'private_var' в функции get_private_var
    local success = mock:mock_upvalue(test_module.get_private_var, "private_var", "mocked_value_get")
    Assert.is_true(success, "mock_upvalue для get_private_var должен быть успешным")
    Assert.are_equal("mocked_value_get", test_module.get_private_var(), "После мокирования get_private_var")

    -- Мокируем upvalue 'private_var' в функции set_private_var
    success = mock:mock_upvalue(test_module.set_private_var, "private_var", "mocked_value_set")
    Assert.is_true(success, "mock_upvalue для set_private_var должен быть успешным")
    test_module.set_private_var("new_value_via_mocked_set")
    Assert.are_equal("new_value_via_mocked_set", test_module.get_private_var(), "После вызова set_private_var с замоканным upvalue")

    mock:restore()
    Assert.are_equal("original_private_value", test_module.get_private_var(), "Upvalue должен быть восстановлен")
end)

my_suite:add_test("test_get_function_upvalues", function()
    local mock = Mock:new()
    local test_module = create_test_module()

    local upvalues = mock:get_function_upvalues(test_module.get_private_var)
    Assert.is_not_nil(upvalues.private_var, "Должен найти upvalue 'private_var'")
    Assert.are_equal("original_private_value", upvalues.private_var, "Значение upvalue должно быть оригинальным")

    mock:restore()
end)

my_suite:add_test("test_get_module_upvalues", function()
    local mock = Mock:new()
    local test_module = create_test_module()

    local module_upvalues = mock:get_module_upvalues(test_module)
    Assert.is_not_nil(module_upvalues[test_module.get_private_var], "Должны быть upvalue для get_private_var")
    Assert.is_not_nil(module_upvalues[test_module.set_private_var], "Должны быть upvalue для set_private_var")

    Assert.are_equal("original_private_value", module_upvalues[test_module.get_private_var].private_var, "Значение upvalue get_private_var")
    Assert.are_equal("original_private_value", module_upvalues[test_module.set_private_var].private_var, "Значение upvalue set_private_var")

    mock:restore()
end)

my_suite:run()
```

## 6. Использование `test_profiler.lua`

`test_profiler.lua` предоставляет класс `Profiler` для измерения времени выполнения и потребления памяти.

*   **`Profiler:new()`**: Создает новый экземпляр профилировщика.
*   **`profiler:start()`**: Начинает отсчет времени и фиксирует текущее потребление памяти.
*   **`profiler:stop(name)`**: Останавливает отсчет и сохраняет результаты (время и изменение памяти) под указанным `name`.
*   **`profiler:report()`**: Выводит отчет со всеми собранными метриками.

Пример использования `Profiler`:
```lua
local test_helper = require("test_helper")
local TestSuite = test_helper.TestSuite
local Profiler = require("test_profiler")

local my_suite = TestSuite:new("Profiler Tests")

my_suite:add_test("test_performance_of_loop", function()
    local profiler = Profiler:new()
    profiler:start()

    local sum = 0
    for i = 1, 1000000 do
        sum = sum + i
    end

    profiler:stop("Million Loop")
    profiler:report() -- Отчет будет выведен в консоль
end)

my_suite:run()
```

## 7. Сбор покрытия кода (Luacov)

`run_test.lua` автоматически интегрируется с Luacov. Если Luacov успешно инициализирован, он будет собирать статистику покрытия кода для всех запущенных тестовых файлов.
После завершения всех тестов, `run_test.lua` вызывает `luacov_runner.shutdown()` и пытается прочитать и вывести сводку из файла отчета `luacov.report.out`, который находится в `/opt/astra/lib-monitor/test/`.

Для просмотра полного отчета покрытия кода после запуска тестов, вы можете открыть файл `/opt/astra/lib-monitor/test/luacov.report.out` в текстовом редакторе.

## 8. Рекомендации

*   **Изоляция тестов**: Всегда используйте `Mock:restore()` после каждого теста, который изменяет глобальное состояние или мокирует зависимости, чтобы гарантировать, что тесты не влияют друг на друга.
*   **Организация**: Группируйте связанные тесты в `TestSuite`.
*   **Именование**: Давайте тестам и тестовым наборам осмысленные имена.
*   **Покрытие**: Стремитесь к высокому покрытию кода, используя Luacov для отслеживания.
*   **Производительность**: Используйте `Profiler` для выявления узких мест в коде.
