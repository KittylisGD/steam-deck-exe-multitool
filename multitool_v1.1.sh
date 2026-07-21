#!/bin/bash

# Steam Deck EXE Multitool v1.1
# Улучшенная версия с исправлением багов и новыми функциями

DOWNLOADS_DIR="/home/deck/Downloads"
STEAM_ROOT="/home/deck/.local/share/Steam"
COMPAT_DATA_BASE="$STEAM_ROOT/steamapps/compatdata"
COMPAT_TOOLS_BASE="$STEAM_ROOT/compatibilitytools.d"

# Цвета для вывода в консоль (если запущен не через GUI)
GREEN='\033[0;32m'
NC='\033[0m'

# Исправленная функция поиска Proton (учитывает пробелы в названиях)
find_proton_versions() {
    local common_dir="$STEAM_ROOT/steamapps/common"
    local custom_dir="$COMPAT_TOOLS_BASE"
    
    # Собираем все папки Proton в один список
    (
        [ -d "$common_dir" ] && find "$common_dir" -maxdepth 1 -type d -name "Proton*" -printf "%f\n"
        [ -d "$custom_dir" ] && find "$custom_dir" -maxdepth 1 -type d -printf "%f\n"
    ) | sort -u
}

# Функция для скачивания GE-Proton (пример новой функции)
download_ge_proton() {
    zenity --info --text="Поиск последних версий GE-Proton на GitHub..."
    
    # Получаем список релизов GE-Proton через GitHub API (публичный эндпоинт)
    RELEASES=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases | grep "tag_name" | cut -d '"' -f 4 | head -n 5)
    
    if [ -z "$RELEASES" ]; then
        zenity --error --text="Не удалось получить список релизов. Проверьте интернет."
        return
    fi
    
    SELECTED_GE=$(echo "$RELEASES" | zenity --list --title="Выберите версию GE-Proton для установки" --column="Версия")
    
    if [ ! -z "$SELECTED_GE" ]; then
        zenity --question --text="Вы уверены, что хотите скачать и установить $SELECTED_GE?\nЭто займет некоторое время."
        if [ $? -eq 0 ]; then
            # Создаем папку если нет
            mkdir -p "$COMPAT_TOOLS_BASE"
            
            # Получаем URL для скачивания .tar.gz
            DOWNLOAD_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$SELECTED_GE/$SELECTED_GE.tar.gz"
            
            (
            echo "10" ; sleep 1
            echo "# Скачивание $SELECTED_GE..."
            curl -L "$DOWNLOAD_URL" -o "$DOWNLOADS_DIR/$SELECTED_GE.tar.gz"
            echo "60" ; sleep 1
            echo "# Распаковка..."
            tar -xf "$DOWNLOADS_DIR/$SELECTED_GE.tar.gz" -C "$COMPAT_TOOLS_BASE/"
            echo "100" ; sleep 1
            echo "# Готово!"
            ) | zenity --progress --title="Установка GE-Proton" --auto-close --percentage=0
            
            zenity --info --text="Установка завершена. Перезапустите Steam, чтобы увидеть новую версию."
        fi
    fi
}

# Главное меню с улучшенным дизайном
main_menu() {
    CHOICE=$(zenity --list --title="Steam Deck Multitool v1.1" \
        --width=500 --height=400 \
        --column="ID" --column="Действие" --hide-column=1 \
        "1" "🚀 Запустить / Установить .exe" \
        "2" "📦 Управление префиксами (Compatdata)" \
        "3" "🌐 Скачать новые средства совместимости (GE-Proton)" \
        "4" "🛠 Настройки и Инфо")
    
    case "$CHOICE" in
        "1") select_and_run ;;
        "2") manage_prefixes ;;
        "3") download_ge_proton ;;
        "4") zenity --info --text="Steam Deck EXE Multitool v1.1\nСоздано для удобного запуска игр." ;;
        *) exit 0 ;;
    esac
}

# Исправленный выбор и запуск
select_and_run() {
    EXE_PATH=$(zenity --file-selection --title="Выберите .exe файл" --file-filter="*.exe")
    [ -z "$EXE_PATH" ] && main_menu

    EXE_NAME=$(basename "$EXE_PATH")
    
    # Исправленный выбор Proton (используем --column для корректного захвата всей строки)
    PROTON_LIST=$(find_proton_versions)
    # Форматируем список для zenity, чтобы избежать разделения по пробелам
    IFS=$'\n'
    PROTON_VERSION=$(echo "$PROTON_LIST" | zenity --list --title="Выберите Proton" --column="Версия" --width=400 --height=300)
    unset IFS

    [ -z "$PROTON_VERSION" ] && main_menu

    # Определение пути к бинарнику Proton
    if [ -d "$STEAM_ROOT/steamapps/common/$PROTON_VERSION" ]; then
        PROTON_BIN="$STEAM_ROOT/steamapps/common/$PROTON_VERSION/proton"
    else
        PROTON_BIN="$COMPAT_TOOLS_BASE/$PROTON_VERSION/proton"
    fi

    # Уникальный префикс
    PREFIX_ID=$(echo "$EXE_PATH" | md5sum | cut -c1-8)
    export STEAM_COMPAT_DATA_PATH="$COMPAT_DATA_BASE/multitool_$PREFIX_ID"
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
    
    mkdir -p "$STEAM_COMPAT_DATA_PATH"

    ACTION=$(zenity --list --title="Действие для $EXE_NAME" --column="Действие" \
        "Запустить сейчас" \
        "Создать .sh обертку в Downloads" \
        "Запустить и создать обертку")

    case "$ACTION" in
        "Запустить сейчас")
            "$PROTON_BIN" run "$EXE_PATH"
            ;;
        "Создать .sh обертку в Downloads")
            create_wrapper "$EXE_PATH" "$PROTON_BIN"
            ;;
        "Запустить и создать обертку")
            create_wrapper "$EXE_PATH" "$PROTON_BIN"
            "$PROTON_BIN" run "$EXE_PATH"
            ;;
    esac
    main_menu
}

create_wrapper() {
    local target_exe="$1"
    local p_bin="$2"
    local original_name=$(basename "$target_exe")
    local wrapper_path="$DOWNLOADS_DIR/$original_name.sh"

    cat <<EOF > "$wrapper_path"
#!/bin/bash
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
export STEAM_COMPAT_DATA_PATH="$STEAM_COMPAT_DATA_PATH"
"$p_bin" run "$target_exe"
EOF
    chmod +x "$wrapper_path"
    zenity --info --text="Скрипт создан:\n$wrapper_path"
}

manage_prefixes() {
    PREFIX=$(ls "$COMPAT_DATA_BASE" | grep "multitool_" | zenity --list --title="Ваши префиксы" --column="Папка")
    if [ ! -z "$PREFIX" ]; then
        SUB_ACTION=$(zenity --list --title="Управление $PREFIX" --column="Действие" "Открыть в проводнике" "Удалить префикс")
        case "$SUB_ACTION" in
            "Открыть в проводнике") dbus-send --session --print-reply --dest=org.freedesktop.FileManager1 /org/freedesktop/FileManager1 org.freedesktop.FileManager1.ShowItems array:string:"file://$COMPAT_DATA_BASE/$PREFIX" string:"" ;;
            "Удалить префикс") rm -rf "$COMPAT_DATA_BASE/$PREFIX" && zenity --info --text="Удалено" ;;
        esac
    fi
    main_menu
}

# Запуск
main_menu
