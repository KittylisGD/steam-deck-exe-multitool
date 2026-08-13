#!/bin/bash

# Steam Deck EXE Multitool v1.2
# "Lutris-lite" edition with Game Library and Advanced Config

# Конфигурация
CONFIG_DIR="/home/deck/.config/multitool"
LIBRARY_FILE="$CONFIG_DIR/library.db"
DOWNLOADS_DIR="/home/deck/Downloads"
STEAM_ROOT="/home/deck/.local/share/Steam"
COMPAT_DATA_BASE="$STEAM_ROOT/steamapps/compatdata"
COMPAT_TOOLS_BASE="$STEAM_ROOT/compatibilitytools.d"

mkdir -p "$CONFIG_DIR"
touch "$LIBRARY_FILE"

# Поиск Proton
find_proton_versions() {
    (
        [ -d "$STEAM_ROOT/steamapps/common" ] && find "$STEAM_ROOT/steamapps/common" -maxdepth 1 -type d -name "Proton*" -printf "%f\n"
        [ -d "$COMPAT_TOOLS_BASE" ] && find "$COMPAT_TOOLS_BASE" -maxdepth 1 -type d -printf "%f\n"
    ) | sort -u
}

get_proton_bin() {
    local version="$1"
    if [ -d "$STEAM_ROOT/steamapps/common/$version" ]; then
        echo "$STEAM_ROOT/steamapps/common/$version/proton"
    else
        echo "$COMPAT_TOOLS_BASE/$version/proton"
    fi
}

# Главное меню
main_library() {
    local list_data=()
    while IFS='|' read -r name path proton prefix env; do
        [ -z "$name" ] && continue
        list_data+=("🎮" "$name" "$proton")
    done < "$LIBRARY_FILE"

    CHOICE=$(zenity --list --title="Multitool Library v1.2" \
        --width=700 --height=500 \
        --column=" " --column="Название игры" --column="Версия Proton" \
        "${list_data[@]}" \
        --extra-button "➕ Добавить новую" \
        --extra-button "🌐 Установка GE-Proton" \
        --extra-button "⚙️ Настройки")

    case "$?" in
        0) 
            [ -z "$CHOICE" ] && main_library
            manage_game "$CHOICE"
            ;;
        1) exit 0 ;;
        *)
            if [[ "$CHOICE" == "➕ Добавить новую" ]]; then add_new_game; fi
            if [[ "$CHOICE" == "🌐 Установка GE-Proton" ]]; then download_ge_proton; fi
            if [[ "$CHOICE" == "⚙️ Настройки" ]]; then global_settings; fi
            main_library
            ;;
    esac
}

manage_game() {
    local game_name="$1"
    local entry=$(grep "^$game_name|" "$LIBRARY_FILE")
    IFS='|' read -r name path proton prefix env <<< "$entry"
    
    ACTION=$(zenity --list --title="Управление: $name" \
        --width=450 --height=450 \
        --column="Действие" \
        "🚀 Запустить игру" \
        "📝 Изменить параметры запуска" \
        "📂 Открыть папку префикса" \
        "🍷 Winetricks" \
        "📜 Создать ярлык .sh" \
        "🗑 Удалить из библиотеки")

    case "$ACTION" in
        "🚀 Запустить игру") run_game "$path" "$proton" "$prefix" "$env" ;;
        "📝 Изменить параметры запуска") edit_game "$name" ;;
        "📂 Открыть папку префикса") dbus-send --session --print-reply --dest=org.freedesktop.FileManager1 /org/freedesktop/FileManager1 org.freedesktop.FileManager1.ShowItems array:string:"file://$prefix" string:"" ;;
        "🍷 Winetricks") 
            export STEAM_COMPAT_DATA_PATH="$prefix"
            protontricks --appid 0 winetricks || zenity --error --text="Protontricks не найден!"
            ;;
        "📜 Создать ярлык .sh") create_wrapper "$name" "$path" "$proton" "$prefix" "$env" ;;
        "🗑 Удалить из библиотеки") 
            sed -i "/^$name|/d" "$LIBRARY_FILE"
            zenity --info --text="Игра удалена."
            ;;
    esac
    main_library
}

run_game() {
    local path="$1"
    local proton="$2"
    local prefix="$3"
    local env="$4"
    local p_bin=$(get_proton_bin "$proton")
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
    export STEAM_COMPAT_DATA_PATH="$prefix"
    # Применяем переменные
    export $(echo "$env" | xargs)
    "$p_bin" run "$path" &
}

add_new_game() {
    EXE_PATH=$(zenity --file-selection --title="Выберите .exe игры" --file-filter="*.exe")
    [ -z "$EXE_PATH" ] && return
    NAME=$(zenity --entry --title="Название игры" --text="Введите название:")
    [ -z "$NAME" ] && return
    
    IFS=$'\n'
    PROTON_VERSION=$(find_proton_versions | zenity --list --title="Выберите Proton" --column="Версия")
    unset IFS
    [ -z "$PROTON_VERSION" ] && return

    PREFIX_ID=$(echo "$EXE_PATH" | md5sum | cut -c1-8)
    PREFIX_PATH="$COMPAT_DATA_BASE/multitool_$PREFIX_ID"
    mkdir -p "$PREFIX_PATH"
    
    ENV_VARS=$(zenity --entry --title="Параметры" --text="Переменные (например MANGOHUD=1):" --entry-text="MANGOHUD=0")
    echo "$NAME|$EXE_PATH|$PROTON_VERSION|$PREFIX_PATH|$ENV_VARS" >> "$LIBRARY_FILE"
}

edit_game() {
    local old_name="$1"
    local entry=$(grep "^$old_name|" "$LIBRARY_FILE")
    IFS='|' read -r name path proton prefix env <<< "$entry"
    NEW_ENV=$(zenity --entry --title="Редактирование" --text="Параметры запуска:" --entry-text="$env")
    [ ! -z "$NEW_ENV" ] && sed -i "s|^$old_name|.*|$name|$path|$proton|$prefix|$NEW_ENV|" "$LIBRARY_FILE"
}

create_wrapper() {
    local name="$1" path="$2" proton="$3" prefix="$4" env="$5"
    local p_bin=$(get_proton_bin "$proton")
    cat <<EOF > "$DOWNLOADS_DIR/$name.sh"
#!/bin/bash
export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
export STEAM_COMPAT_DATA_PATH="$prefix"
$env "$p_bin" run "$path"
EOF
    chmod +x "$DOWNLOADS_DIR/$name.sh"
    zenity --info --text="Создано: $name.sh"
}

download_ge_proton() {
    RELEASES=$(curl -s https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases | grep "tag_name" | cut -d '"' -f 4 | head -n 5)
    SELECTED_GE=$(echo "$RELEASES" | zenity --list --title="Установка GE-Proton" --column="Версия")
    if [ ! -z "$SELECTED_GE" ]; then
        mkdir -p "$COMPAT_TOOLS_BASE"
        DOWNLOAD_URL="https://github.com/GloriousEggroll/proton-ge-custom/releases/download/$SELECTED_GE/$SELECTED_GE.tar.gz"
        (
            echo "10" ; curl -L "$DOWNLOAD_URL" -o "$DOWNLOADS_DIR/$SELECTED_GE.tar.gz"
            echo "60" ; tar -xf "$DOWNLOADS_DIR/$SELECTED_GE.tar.gz" -C "$COMPAT_TOOLS_BASE/"
            echo "100"
        ) | zenity --progress --title="Установка" --auto-close
    fi
}

global_settings() {
    zenity --info --text="Steam Deck Multitool v1.2\nLibrary: $LIBRARY_FILE"
}

main_library
