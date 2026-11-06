<div align="center">

# X6 Control

**Управление игровой мышью Attack Shark X6 на macOS**

Настрой DPI, частоту опроса, RGB-подсветку и кнопки — прямо с Mac.

[![macOS](https://img.shields.io/badge/macOS-13%2B-555555?logo=apple&logoColor=white)](https://www.apple.com/macos/)
[![Swift](https://img.shields.io/badge/Swift-App-orange?logo=swift&logoColor=white)](https://www.swift.org/)
[![Python](https://img.shields.io/badge/Python-Backend-3776AB?logo=python&logoColor=white)](https://www.python.org/)
[![GitHub Actions](https://img.shields.io/github/actions/workflow/status/0xDEADBEEF-cpu/X6Control/ci.yml?branch=main&label=CI&logo=githubactions&logoColor=white)](https://github.com/0xDEADBEEF-cpu/X6Control/actions/workflows/ci.yml)
[![Release](https://img.shields.io/github/v/release/0xDEADBEEF-cpu/X6Control?display_name=tag&logo=github)](https://github.com/0xDEADBEEF-cpu/X6Control/releases)
[![License](https://img.shields.io/badge/license-MIT-green.svg)](LICENSE)

</div>

---

## Возможности

| Функция | Что можно настроить |
| --- | --- |
| **DPI** | 6 уровней чувствительности с шагом 50 |
| **Частота опроса** | 125, 250, 500 и 1 000 Гц |
| **RGB-подсветка** | 7 режимов, цвет, скорость эффектов и таймер сна |
| **Сенсор** | Угол, сглаживание дрожания, высота отрыва и debounce |
| **Кнопки** | Переназначение семи физических кнопок |
| **Профили** | Локальное сохранение, применение и сброс настроек |

## Совместимость

- macOS 13 Ventura и новее.
- Mac с процессором Intel или Apple Silicon.
- Attack Shark X6, подключённая по USB или через комплектный радиоприёмник 2,4 ГГц.

Поддерживаются USB-идентификаторы мыши `1d57:fa61` и приёмника `1d57:fa60`.

> Подключение по Bluetooth и редактор макросов не поддерживаются.

## Установка

1. Открой вкладку [Releases](https://github.com/0xDEADBEEF-cpu/X6Control/releases).
2. Скачай ZIP-архив или DMG-образ последней версии.
3. Если скачан ZIP — распакуй его.
4. Перемести **X6 Control.app** в папку «Программы».
5. Подключи мышь и запусти приложение.

Если macOS предупредит, что приложение загружено из интернета, открой его через Finder: нажми правой кнопкой мыши на приложение и выбери **Открыть**. Подтверди запуск в появившемся окне.

## Важные особенности

- Настройки профилей хранятся локально на Mac.
- Изменения отправляются мыши после нажатия кнопки применения.
- Мышь не позволяет прочитать сохранённую в ней конфигурацию. Поэтому приложение показывает настройки выбранного локального профиля, а не считывает их из памяти мыши.

## Обратная связь

Нашёл ошибку или хочешь предложить улучшение? [Создай Issue](https://github.com/0xDEADBEEF-cpu/X6Control/issues).

## Лицензия

Проект распространяется под лицензией [MIT](LICENSE).
