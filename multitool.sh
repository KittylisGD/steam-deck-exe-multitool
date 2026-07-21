#!/bin/bash

# Steam Deck EXE Multitool
# Скрипт для запуска установщиков и игр .exe с созданием оберток .sh

DOWNLOADS_DIR="/home/deck/Downloads"
STEAM_ROOT="/home/deck/.local/share/Steam"
COMPAT_DATA_BASE="$STEAM_ROOT/steamapps/compatdata"

# Функция для поиска установленных версий Proton
find_proton_versions() {
    local common_dir="$STEAM_ROOT/steamapps/common"
    if [ -d "$common_dir" ]; then
        find "$common_dir" -maxdepth 1 -type d -name "Proton*" | xargs -n1 basename
    else
        echo "Proton-8.0" # Fallback
    fi
}

# Проверка наличия zenity
if ! command -v zenity &> /dev/null; then
    echo "Zenity is required for GUI. Please install it."
    # В реальной среде Steam Deck zenity предустановлен
fi

# Выбор файла
EXE_PATH=$(zenity --file-selection --title="Выберите .exe файл (Setup или Игра)" --file-filter="*.exe")

if [ -z "$EXE_PATH" ]; then
    exit 0
fi

EXE_NAME=$(basename "$EXE_PATH")
EXE_DIR=$(dirname "$EXE_PATH")

# Выбор действия
ACTION=$(zenity --list --title="Выберите действие" --column="Действие" \
    "Установить (setup.exe)" \
    "Запустить игру" \
    "Создать только скрипт-обертку")

if [ -z "$ACTION" ]; then
    exit 0
fi

# Выбор версии Proton
PROTON_VERSIONS=$(find_proton_versions)
PROTON_VERSION=$(echo "$PROTON_VERSIONS" | zenity --list --title="Выберите версию Proton" --column="Версия")

if [ -z "$PROTON_VERSION" ]; then
    PROTON_VERSION="Proton 8.0"
fi

# Пути окружения
PROTON_BIN="/home/deck/.local/share/Steam/steamapps/common/$PROTON_VERSION/proton"
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"

# Генерируем уникальный ID для префикса на основе пути к файлу
PREFIX_ID=$(echo "$EXE_PATH" | md5sum | cut -c1-8)
export STEAM_COMPAT_DATA_PATH="$COMPAT_DATA_BASE/multitool_$PREFIX_ID"

mkdir -p "$STEAM_COMPAT_DATA_PATH"

# Функция создания скрипта-обертки
create_wrapper() {
    local target_exe="$1"
    local original_name=$(basename "$target_exe")
    local wrapper_path="$DOWNLOADS_DIR/$original_name.sh"

    cat <<EOF > "$wrapper_path"
#!/bin/bash
# Автоматически созданный скрипт для запуска $original_name
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
export STEAM_COMPAT_DATA_PATH="$STEAM_COMPAT_DATA_PATH"
"$PROTON_BIN" run "$target_exe"
EOF
    chmod +x "$wrapper_path"
    zenity --info --text="Скрипт-обертка создан в:\n$wrapper_path"
}

case "$ACTION" in
    "Установить (setup.exe)")
        zenity --info --text="Запуск установки... Пожалуйста, следуйте инструкциям инсталлятора."
        "$PROTON_BIN" run "$EXE_PATH"
        
        zenity --question --text="Установка завершена. Хотите найти установленный .exe файл игры, чтобы создать для него быстрый запуск (.sh)?"
        if [ $? -eq 0 ]; then
            # Пытаемся открыть проводник в префиксе
            INSTALLED_EXE=$(zenity --file-selection --title="Выберите .exe игры в папке установки" --filename="$STEAM_COMPAT_DATA_PATH/pfx/drive_c/")
            if [ ! -z "$INSTALLED_EXE" ]; then
                create_wrapper "$INSTALLED_EXE"
            fi
        fi
        ;;
    "Запустить игру")
        create_wrapper "$EXE_PATH"
        "$PROTON_BIN" run "$EXE_PATH"
        ;;
    "Создать только скрипт-обертку")
        create_wrapper "$EXE_PATH"
        ;;
esac
