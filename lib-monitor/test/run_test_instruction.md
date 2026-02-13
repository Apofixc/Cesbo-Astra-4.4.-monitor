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

**Важно:** `astra4.4.182` или `astra4.4.187cw` не поддерживают внешние библиотеки на C.

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

Тесты расположены в ``test/<тип_теста>/<путь_к_файлу_в_src_без_src_и_имени_файла>/test_<имя_файла_без_расширения>.lua`.
Имя каждого тестового файла должно начинаться с префикса `test_` (например, `test_monitor_config.lua`).

Внутри каждого тестового файла рекомендуется использовать `TestSuite` из `test_helper.lua` для организации тестов.

Пример структуры тестового файла:
```lua
local test_helper = require("test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
-- Подключение необходимых тестовых утилит
local TestSuite = require("astra/lib-monitor/test/tools/test_helper").TestSuite
local Assert = require("astra/lib-monitor/test/tools/test_helper").Assert
local Mock = require("astra/lib-monitor/test/tools/test_moc")

-- Объявление глобальных переменных для моков и перехвата коллбэков
-- Эти переменные будут использоваться для имитации внешних зависимостей
-- и отслеживания их вызовов.
local mock
local local_mock
-- Пример: local mock_logger_calls
-- Пример: local mock_dependency_instance
-- Пример: local mock_global_function_result

-- Переменная для модуля, который мы тестируем
local ModuleUnderTest -- Будет загружен в before_each

-- Создание нового набора тестов
local suite = TestSuite:new("Название набора тестов")

--- @function suite:setup
-- Вызывается один раз перед всеми тестами в наборе.
-- Используется для инициализации моков и глобальных зависимостей.
suite:setup(function()
    mock = Mock:new()

    -- Инициализация моков для внешних зависимостей
    -- Пример:
    -- mock_logger_calls = { debug = 0, info = 0, warning = 0, error = 0 }
    -- local mock_logger = {
    --     debug = function(...) mock_logger_calls.debug = mock_logger_calls.debug + 1 end,
    --     info = function(...) mock_logger_calls.info = mock_logger_calls.info + 1 end,
    --     error = function(...) mock_logger_calls.error = mock_logger_calls.error + 1 end,
    -- }

    -- Мокирование глобальных зависимостей через ModuleManager или напрямую
    -- Пример:
    -- mock:mock_global("ModuleManager", {
    --     get_module = function(name)
    --         if name == "logger" then return mock_logger end
    --         return nil
    --     end,
    --     get_global_dependency = function(name)
    --         if name == "json.load" then return function(path) return mock_json_load_result end end
    --         return nil
    --     end
    -- })

    -- Мокирование других глобальных функций или таблиц
    -- Пример:
    -- mock:mock_global("os", { time = function() return 1000 end })
end)

--- @function suite:before_each
-- Вызывается перед каждым отдельным тестом.
-- Используется для сброса состояния моков и счетчиков, а также для чистой загрузки тестируемого модуля.
suite:before_each(function()
    -- Сброс состояния моков и счетчиков перед каждым тестом
    -- Пример:
    -- mock_logger_calls.debug = 0
    -- mock_json_load_result = nil

    -- Очистка кэша модуля для обеспечения чистой загрузки.
    -- Замените "путь/к/вашему/модулю" на фактический путь.
    package.loaded["astra/lib-monitor/src/config/monitor_config"] = nil -- Пример
    -- Загрузка тестируемого модуля
    ModuleUnderTest = require("astra/lib-monitor/src/config/monitor_config") -- Пример
end)

suite:after_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
end)

--- @function suite:teardown
-- Вызывается один раз после всех тестов в наборе.
-- Используется для восстановления глобальных переменных в их исходное состояние.
suite:teardown(function()
    mock:restore()
end)

-- ===========================================================================
-- Тестовые сценарии
-- ===========================================================================

--- @function suite:add_test
-- Добавление отдельного тестового случая.
-- Название теста должно быть описательным.
suite:add_test("Название тестового случая: должен делать X при условии Y", function()
    -- 1. Подготовка (Arrange): Установка начальных условий, настройка моков.
    -- Пример:
    -- mock_json_load_result = { Key = "Value" }

    -- 2. Действие (Act): Вызов тестируемой функции или метода.
    -- Пример:
    -- local result = ModuleUnderTest.some_function()

    -- 3. Проверка (Assert): Проверка ожидаемых результатов с помощью Assert.
    -- Пример:
    -- Assert.is_true(result, "Функция должна вернуть true")
    -- Assert.are_equal("Value", ModuleUnderTest.Key, "Значение должно быть 'Value'")
    -- Assert.are_equal(1, mock_logger_calls.info, "Должно быть одно информационное сообщение")
end)

-- Добавьте отдельного тестового случая с использование моков в тестах
suite:add_test("Другой тестовый случай: должен обрабатывать ошибки", function()
    -- 1. Подготовка локальных моков
    -- local_mock = Mock:new()
    -- local original_log_info = log.info -- Сохраняем оригинал для проверки
    -- local_mock:mock_global("log", { info = function(msg) print("MOCKED LOG: " .. msg) end })

    -- 2. Проводим тестирование  
    -- log.info("Hello from mock!")
    -- Assert.is_not_nil(log, "log не должен быть nil")
    -- Assert.is_not_nil(log.info, "log.info не должен быть nil")
    -- -- Здесь можно добавить проверку, что "MOCKED LOG: Hello from mock!" было выведено
    -- -- (что сложнее в автоматизированных тестах без перехвата stdout)

    -- Assert.are_equal(original_log_info, log.info, "log.info должен быть восстановлен")
end)


-- Добавьте больше тестовых случаев по мере необходимости
suite:add_test("Другой тестовый случай: должен обрабатывать ошибки", function()
    -- Подготовка
    -- Действие
    -- Проверка
end)

-- Запуск всех тестов в наборе
suite:run()
```

## 4. Использование `test_helper.lua`

`test_helper.lua` предоставляет базовые инструменты для написания тестов: `TestSuite` для группировки тестов и `Assert` для выполнения утверждений.

*   **`TestSuite`**
    *   `TestSuite:new(name)`: Создает новый тестовый набор с указанным именем.
    *   `suite:add_test(test_name, func)`: Добавляет тестовую функцию в набор. `test_name` — это строка, `func` — функция, содержащая логику теста и утверждения.
    *   `suite:run()`: Запускает все тесты в наборе. Выводит статус каждого теста (УСПЕХ/ОШИБКА).

    **Расширенная логика `before_each` и `after_each`:**
    Методы `suite:before_each` и `suite:after_each` теперь поддерживают два режима использования:
    *   `suite:before_each(func)` / `suite:after_each(func)`: Если передан только один аргумент (функция), она будет установлена как глобальная функция, которая будет выполняться перед/после *каждым* тестом в наборе.
    *   `suite:before_each(test_name, func)` / `suite:after_each(test_name, func)`: Если переданы два аргумента (строка `test_name` и функция `func`), `func` будет выполняться только перед/после теста с именем `test_name`. Если для конкретного теста определена специфичная функция, она имеет приоритет над глобальной.

    Пример:
    ```lua
    local suite = TestSuite:new("Мой тестовый набор")

    -- Глобальный before_each
    suite:before_each(function()
        print("  [ГЛОБАЛЬНЫЙ BeforeEach] Выполняется перед каждым тестом.")
    end)

    -- Специфичный before_each для "Тест 1"
    suite:before_each("Тест 1", function()
        print("  [СПЕЦИФИЧНЫЙ BeforeEach] Выполняется только для 'Тест 1'.")
    end)

    suite:add_test("Тест 1", function()
        -- Здесь будет вызван специфичный BeforeEach для "Тест 1"
    end)

    suite:add_test("Тест 2", function()
        -- Здесь будет вызван глобальный BeforeEach
    end)

    suite:run()
    ```

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

`test_moc.lua` предоставляет класс `Mock` для изоляции тестируемого кода от его зависимостей путем мокирования глобальных переменных, полей таблиц и локальных переменных (upvalue). Если таблица/переменная/функция локальная, или кэшируется во время загрузки модуля, то мокироваться должна до загрузки модулей. Если таблица/переменная/функция глобальная, то в любое время.

При мокировании важно учитывать область видимости: если таблица/переменная/функция локальная или кэшируется во время загрузки модуля, то мокирование должно происходить *до* загрузки модулей. Если таблица/переменная/функция глобальная, то мокировать можно в любое время.

*   **`Mock:new()`**: Создает новый экземпляр мока. **Важно: При требовний любового обращения к методом мок в `add_test` для изоляций нужно создавать отдельный локальный экземплял класса мок в пределах `add_test`**
*   **`mock:mock_field(table, name, value)`**: Мокирует поле `name` в таблице `table` новым `value`. **Важно: при мокировании методов класса, передавайте `self` как первый аргумент в функцию-мок, например `mock:mock_field(my_class_instance, "method_name", function(self, ...) ... end)`**
*   **`mock_upvalue(func, name, value)`**: Мокирует локальную переменную (upvalue) `name` внутри функции `func` новым `value`. Используется для приватных переменных модуля.
*   **`mock:restore()`**: Восстанавливает все замоканные значения до их оригинального состояния. **Крайне важно вызывать этот метод после каждого теста, использующего моки, чтобы избежать влияния на другие тесты.**
*   **`mock:get_function_upvalues(func)`**: Возвращает таблицу всех upvalue (локальных переменных) для данной функции `func` в формате `имя -> значение`.

Пример использования `Mock`:
```lua
local test_helper = require("test_helper")
local TestSuite = test_helper.TestSuite
local Assert = test_helper.Assert
local Mock = require("test_moc")

local local_mock

local my_suite = TestSuite:new("Mocking Tests")

suite:setup(function()
    mock = Mock:new()
    
    mock:mock_global("ModuleManager", {
        get_module = function(name)
            if name == "logger" then return mock_logger end
            if name == "core.event_dispatcher" then return mock_event_dispatcher_module end
            return nil
        end,
        get_global_dependency = function(name)
            if name == "json.load" then return function(path) return mock_json_load_result end end
            if name == "json.save" then return function(path, data)
                if mock_json_save_success then
                    return true
                else
                    error("simulated save error")
                end
            end end
            return nil
        end
    })
end)

suite:after_each(function()
    if local_mock then
        local_mock:restore()
        local_mock = nil
    end
end)

suite:teardown(function()
    mock:restore()
end)

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
    local_mock = Mock:new()
    local original_log_info = log.info -- Сохраняем оригинал для проверки

    local_mock:mock_global("log", { info = function(msg) print("MOCKED LOG: " .. msg) end })
    log.info("Hello from mock!")
    Assert.is_not_nil(log, "log не должен быть nil")
    Assert.is_not_nil(log.info, "log.info не должен быть nil")
    -- Здесь можно добавить проверку, что "MOCKED LOG: Hello from mock!" было выведено
    -- (что сложнее в автоматизированных тестах без перехвата stdout)

    Assert.are_equal(original_log_info, log.info, "log.info должен быть восстановлен")
end)

my_suite:add_test("test_mock_upvalue", function()
    local_mock = Mock:new()
    local test_module = create_test_module()

    Assert.are_equal("original_private_value", test_module.get_private_var(), "До мокирования")

    -- Мокируем upvalue 'private_var' в функции get_private_var
    local success = mock:mock_upvalue(test_module.get_private_var, "private_var", "mocked_value_get")
    Assert.is_true(success, "mock_upvalue для get_private_var должен быть успешным")
    Assert.are_equal("mocked_value_get", test_module.get_private_var(), "После мокирования get_private_var")

    -- Мокируем upvalue 'private_var' в функции set_private_var
    success = local_mock:mock_upvalue(test_module.set_private_var, "private_var", "mocked_value_set")
    Assert.is_true(success, "mock_upvalue для set_private_var должен быть успешным")
    test_module.set_private_var("new_value_via_mocked_set")
    Assert.are_equal("new_value_via_mocked_set", test_module.get_private_var(), "После вызова set_private_var с замоканным upvalue")

    Assert.are_equal("original_private_value", test_module.get_private_var(), "Upvalue должен быть восстановлен")
end)

my_suite:add_test("test_get_function_upvalues", function()
    local_mock = Mock:new()
    local test_module = create_test_module()

    local upvalues = local_mock:get_function_upvalues(test_module.get_private_var)
    Assert.is_not_nil(upvalues.private_var, "Должен найти upvalue 'private_var'")
    Assert.are_equal("original_private_value", upvalues.private_var, "Значение upvalue должно быть оригинальным")
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

*   **Изоляция тестов**: Всегда используйте `Mock:new()` и `Mock:restore()` до/ после каждого теста, который изменяет глобальное состояние или мокирует зависимости, чтобы гарантировать, что тесты не влияют друг на друга.
*   **Моксирования методов классов**: При моксирований методов класса обращайте внимание, чтобы первый передаваемый параметр является `self`.
*   **Организация**: Группируйте связанные тесты в `<Уровень>.<Модуль>`. Стресс тесты в отдельный `<Уровень>.<Модуль>.<Стресс>`
*   **Именование**: Давайте тестам и тестовым наборам осмысленные имена.
*   **Покрытие**: Стремитесь к высокому покрытию кода, используя Luacov для отслеживания.
*   **Производительность**: Используйте `Profiler` для выявления узких мест в коде.
*   **Изоляция**: Использование `_G` для моков действительно нарушает изоляцию тестов. **Поэтому ипользование `_G` для моков запрещенно**
*   **Хаки**: При тестирований в первую очередь проверять, естественное использование модуля.
