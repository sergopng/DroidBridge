# Сторонние компоненты и авторы

| Компонент | Назначение и сведения |
| --- | --- |
| [Android SDK Platform Tools](https://developer.android.com/tools/releases/platform-tools) | ADB и Fastboot 37.0.1. Уведомления Google помещаются в ресурсы приложения из `NOTICE.txt` |
| [scrcpy 5.0.1](https://github.com/Genymobile/scrcpy/tree/v5.0.1) | Клиент и Android-сервер Genymobile для управления экраном. Проект распространяется под Apache 2.0. Официальный клиент macOS включает сторонние зависимости, указанные в его [рецепте сборки](https://github.com/Genymobile/scrcpy/blob/v5.0.1/release/build_macos.sh) |
| [libmtp](https://github.com/libmtp/libmtp) | USB MTP, версия 1.1.22, LGPL 2.1 или новее. Приложение использует динамическую библиотеку |
| [libusb](https://github.com/libusb/libusb) | USB, версия 1.0.29, LGPL 2.1 или новее. Приложение использует динамическую библиотеку |
| [unslop](https://heydamir.design/unslop) | Метод полировки интерфейса, Damir Sokolovsky (@heydamir), CC BY 4.0 |

DMG, созданный скриптом сборки, включает архив исходников libmtp и libusb вместе с патчем macOS и инструкцией по сборке. Тексты лицензий библиотек находятся в ресурсах приложения.

Приведённые лицензии относятся к соответствующим компонентам.
