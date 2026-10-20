#!/usr/bin/env bash
# Steam Deck EXE Multitool v1.3
# Библиотека Windows-приложений, отдельные Proton-префиксы и установка GE-Proton.

set -u

VERSION="1.2"
STEAM_ROOT="${STEAM_ROOT:-/home/deck/.local/share/Steam}"
DOWNLOADS_DIR="${DOWNLOADS_DIR:-/home/deck/Downloads}"
CONFIG_DIR="${CONFIG_DIR:-/home/deck/.config/multitool}"
LIBRARY_FILE="$CONFIG_DIR/library.db"
COMPAT_DATA_BASE="$STEAM_ROOT/steamapps/compatdata"
COMPAT_TOOLS_BASE="$STEAM_ROOT/compatibilitytools.d"
GE_API="https://api.github.com/repos/GloriousEggroll/proton-ge-custom/releases?per_page=10"

mkdir -p "$CONFIG_DIR" "$DOWNLOADS_DIR"
touch "$LIBRARY_FILE"

notify_error() { zenity --error --title="Steam Deck EXE Multitool" --text="$1" 2>/dev/null || printf 'Ошибка: %s\n' "$1" >&2; }
notify_info() { zenity --info --title="Steam Deck EXE Multitool" --text="$1" 2>/dev/null || printf '%s\n' "$1"; }
ask_yesno() { zenity --question --title="Steam Deck EXE Multitool" --text="$1"; }

if ! command -v zenity >/dev/null 2>&1; then
    printf 'Для графического интерфейса требуется Zenity (в SteamOS обычно уже установлен).\n' >&2
    exit 1
fi

# Keep the original pipe-delimited v1.2 library format for compatibility.
find_proton_versions() {
    local base dir
    for base in "$STEAM_ROOT/steamapps/common" "$COMPAT_TOOLS_BASE"; do
        [ -d "$base" ] || continue
        while IFS= read -r -d '' dir; do
            [ -x "$dir/proton" ] && basename "$dir"
        done < <(find "$base" -mindepth 1 -maxdepth 1 -type d -print0 2>/dev/null)
    done | sort -u
}

get_proton_bin() {
    local version="$1" candidate
    for candidate in "$STEAM_ROOT/steamapps/common/$version/proton" "$COMPAT_TOOLS_BASE/$version/proton"; do
        if [ -x "$candidate" ]; then printf '%s\n' "$candidate"; return 0; fi
    done
    return 1
}

# Read one game record by exact game name. Names and fields containing '|' are rejected on save.
get_game_record() {
    local wanted="$1" name path proton prefix env
    while IFS='|' read -r name path proton prefix env; do
        [ "$name" = "$wanted" ] || continue
        printf '%s\n' "$path" "$proton" "$prefix" "${env:-}"
        return 0
    done < "$LIBRARY_FILE"
    return 1
}

library_names() {
    local name path proton prefix env
    while IFS='|' read -r name path proton prefix env; do
        [ -n "$name" ] && printf '%s\n' "$name"
    done < "$LIBRARY_FILE"
}

read_record_fields() {
    local record="$1"
    IFS=$'\n' read -r -d '' -a RECORD_FIELDS < <(printf '%s\0' "$record") || true
}

valid_env_vars() {
    local token
    local -a tokens
    read -r -a tokens <<< "${1:-}"
    for token in "${tokens[@]}"; do
        [[ "$token" =~ ^[A-Za-z_][A-Za-z0-9_]*=.*$ ]] || return 1
    done
    return 0
}

apply_env_vars() {
    local token key value
    local -a tokens
    read -r -a tokens <<< "${1:-}"
    for token in "${tokens[@]}"; do
        key="${token%%=*}"
        value="${token#*=}"
        printf -v "$key" '%s' "$value"
        export "$key"
    done
}

main_library() {
    local choice status
    local -a names=()
    while true; do
        names=()
        mapfile -t names < <(library_names)
        choice=$(zenity --list --title="Steam Deck EXE Multitool v$VERSION" \
            --text="Библиотека игр и Windows-приложений" --width=680 --height=440 \
            --column="Название" "${names[@]}" \
            --extra-button="➕ Добавить игру" \
            --extra-button="🌐 Установить GE-Proton" \
            --extra-button="📦 Управление префиксами" \
            --extra-button="⚙ Диагностика и информация" 2>/dev/null)
        status=$?
        if [ "$status" -eq 0 ] && [ -n "$choice" ]; then
            manage_game "$choice"
        elif [ "$status" -eq 0 ] && [ -z "$choice" ]; then
            exit 0
        else
            case "$choice" in
                "➕ Добавить игру") add_new_game ;;
                "🌐 Установить GE-Proton") download_ge_proton ;;
                "📦 Управление префиксами") manage_prefixes ;;
                "⚙ Диагностика и информация") diagnostics ;;
                *) exit 0 ;;
            esac
        fi
    done
}

manage_game() {
    local game_name="$1" record path proton prefix env action
    record=$(get_game_record "$game_name") || { notify_error "Игра не найдена в библиотеке."; return; }
    mapfile -t fields <<< "$record"
    path="${fields[0]:-}"; proton="${fields[1]:-}"; prefix="${fields[2]:-}"; env="${fields[3]:-}"
    action=$(zenity --list --title="Управление: $game_name" --width=470 --height=420 \
        --column="Действие" "🚀 Запустить" "📝 Параметры запуска" "📂 Открыть папку префикса" \
        "💾 Создать резервную копию префикса" "♻ Восстановить префикс" "🧹 Удалить префикс" \
        "📜 Создать ярлык .sh" "🗑 Удалить игру из библиотеки" 2>/dev/null) || return
    case "$action" in
        "🚀 Запустить") run_game "$game_name" "$path" "$proton" "$prefix" "$env" ;;
        "📝 Параметры запуска") edit_game "$game_name" "$path" "$proton" "$prefix" "$env" ;;
        "📂 Открыть папку префикса") open_folder "$prefix" ;;
        "💾 Создать резервную копию префикса") backup_prefix "$game_name" "$prefix" ;;
        "♻ Восстановить префикс") restore_prefix "$game_name" "$prefix" ;;
        "🧹 Удалить префикс")
            if ! is_managed_prefix "$prefix"; then
                notify_error "Путь к префиксу не соответствует безопасному каталогу multitool. Удаление отменено."
            elif [ -d "$prefix" ] && ask_yesno "Безвозвратно удалить префикс игры «$game_name»? Рекомендуется сначала создать резервную копию."; then
                rm -rf -- "$prefix" && notify_info "Префикс удалён. Запись игры осталась в библиотеке."
            fi ;;
        "📜 Создать ярлык .sh") create_wrapper "$game_name" "$path" "$proton" "$prefix" "$env" ;;
        "🗑 Удалить игру из библиотеки")
            if ask_yesno "Удалить «$game_name» из библиотеки? Файлы игры и префикс останутся на диске."; then
                local tmp="$CONFIG_DIR/library.tmp" name p pr px ev
                : > "$tmp"
                while IFS='|' read -r name p pr px ev; do
                    [ "$name" = "$game_name" ] || printf '%s|%s|%s|%s|%s\n' "$name" "$p" "$pr" "$px" "$ev" >> "$tmp"
                done < "$LIBRARY_FILE"
                mv "$tmp" "$LIBRARY_FILE"
                notify_info "Игра удалена из библиотеки. Префикс не удалялся."
            fi ;;
    esac
}

add_new_game() {
    local exe name proton versions prefix_id prefix env
    exe=$(zenity --file-selection --title="Выберите EXE-файл игры или установщика" --file-filter="Windows-приложения | *.exe" 2>/dev/null) || return
    [ -f "$exe" ] || return
    name=$(zenity --entry --title="Добавить игру" --text="Название в библиотеке:" --entry-text="$(basename "$exe" .exe)" 2>/dev/null) || return
    [ -n "$name" ] || return
    if [[ "$name" == *'|'* || "$name" == *$'\n'* ]]; then notify_error "Название не должно содержать символ | или перевод строки."; return; fi
    if [[ "$exe" == *'|'* || "$exe" == *$'\n'* ]]; then notify_error "Путь к EXE-файлу не должен содержать символ | или перевод строки."; return; fi
    if get_game_record "$name" >/dev/null; then notify_error "Игра с таким названием уже есть в библиотеке."; return; fi
    versions=$(find_proton_versions)
    [ -n "$versions" ] || { notify_error "Не найден Proton. Установите его через Steam или загрузите GE-Proton."; return; }
    proton=$(printf '%s\n' "$versions" | zenity --list --title="Выберите Proton" --column="Версия" --width=420 --height=360 2>/dev/null) || return
    [ -n "$proton" ] || return
    prefix_id=$(printf '%s' "$exe" | sha256sum | cut -c1-12)
    prefix="$COMPAT_DATA_BASE/multitool_$prefix_id"
    mkdir -p "$prefix" || { notify_error "Не удалось создать префикс: $prefix"; return; }
    env=$(zenity --entry --title="Параметры запуска (необязательно)" \
        --text="Переменные через пробел, например: MANGOHUD=1 PROTON_LOG=1 DXVK_HUD=fps" \
        --entry-text="" 2>/dev/null) || return
    if ! valid_env_vars "$env"; then notify_error "Неверный формат. Используйте NAME=value, разделяя переменные пробелами."; return; fi
    printf '%s|%s|%s|%s|%s\n' "$name" "$exe" "$proton" "$prefix" "$env" >> "$LIBRARY_FILE"
    notify_info "«$name» добавлена в библиотеку."
}

run_game() {
    local game_name="$1" path="$2" proton="$3" prefix="$4" env="$5" p_bin
    [ -f "$path" ] || { notify_error "Файл не найден:\n$path\nИзмените путь в параметрах игры."; return; }
    p_bin=$(get_proton_bin "$proton") || { notify_error "Не найден Proton «$proton». Установите эту версию или измените настройки игры."; return; }
    valid_env_vars "$env" || { notify_error "В библиотеке обнаружены параметры запуска с неверным форматом."; return; }
    mkdir -p "$prefix" || { notify_error "Не удалось открыть или создать префикс:\n$prefix"; return; }
    export STEAM_COMPAT_CLIENT_INSTALL_PATH="$STEAM_ROOT"
    export STEAM_COMPAT_DATA_PATH="$prefix"
    apply_env_vars "$env"
    ( "$p_bin" run "$path" ) >> "$CONFIG_DIR/launch.log" 2>&1 &
    notify_info "Запуск «$game_name» начат.\nЖурнал Proton/приложения: $CONFIG_DIR/launch.log\nЧтобы включить Proton-лог, добавьте PROTON_LOG=1 в параметры запуска."
}

edit_game() {
    local name="$1" old_path="$2" old_proton="$3" old_prefix="$4" old_env="$5" field value tmp
    field=$(zenity --list --title="Настройки: $name" --column="Что изменить" \
        "Путь к EXE-файлу" "Версия Proton" "Переменные окружения" 2>/dev/null) || return
    case "$field" in
        "Путь к EXE-файлу") value=$(zenity --file-selection --title="Выберите EXE-файл" --filename="$old_path" --file-filter="*.exe" 2>/dev/null) || return; [ -f "$value" ] || return; old_path="$value" ;;
        "Версия Proton")
            local versions; versions=$(find_proton_versions)
            value=$(printf '%s\n' "$versions" | zenity --list --title="Выберите Proton" --column="Версия" --width=420 --height=360 2>/dev/null) || return
            [ -n "$value" ] || return; old_proton="$value" ;;
        "Переменные окружения")
            value=$(zenity --entry --title="Параметры запуска: $name" \
                --text="Например: MANGOHUD=1 PROTON_LOG=1 DXVK_HUD=fps" --entry-text="$old_env" 2>/dev/null) || return
            valid_env_vars "$value" || { notify_error "Неверный формат. Используйте NAME=value, разделяя переменные пробелами."; return; }
            old_env="$value" ;;
    esac
    tmp="$CONFIG_DIR/library.tmp"; : > "$tmp"
    local n p pr px ev
    while IFS='|' read -r n p pr px ev; do
        if [ "$n" = "$name" ]; then printf '%s|%s|%s|%s|%s\n' "$n" "$old_path" "$old_proton" "$old_prefix" "$old_env" >> "$tmp"
        else printf '%s|%s|%s|%s|%s\n' "$n" "$p" "$pr" "$px" "$ev" >> "$tmp"; fi
    done < "$LIBRARY_FILE"
    mv "$tmp" "$LIBRARY_FILE"
    notify_info "Настройки игры обновлены."
}

shell_quote() { printf '%q' "$1"; }

create_wrapper() {
    local name="$1" path="$2" proton="$3" prefix="$4" env="$5" p_bin wrapper token
    p_bin=$(get_proton_bin "$proton") || { notify_error "Не найден Proton «$proton»."; return; }
    valid_env_vars "$env" || { notify_error "Неверный формат переменных запуска."; return; }
    wrapper="$DOWNLOADS_DIR/$(printf '%s' "$name" | tr '/\\' '__').sh"
    {
        printf '#!/usr/bin/env bash\n'
        printf '# Ярлык Steam Deck EXE Multitool v%s для %s\n' "$VERSION" "$name"
        printf 'export STEAM_COMPAT_CLIENT_INSTALL_PATH=%s\n' "$(shell_quote "$STEAM_ROOT")"
        printf 'export STEAM_COMPAT_DATA_PATH=%s\n' "$(shell_quote "$prefix")"
        local -a tokens
        read -r -a tokens <<< "$env"
        for token in "${tokens[@]}"; do
            printf 'export %s=%s\n' "${token%%=*}" "$(shell_quote "${token#*=}")"
        done
        printf 'exec %s run %s\n' "$(shell_quote "$p_bin")" "$(shell_quote "$path")"
    } > "$wrapper" || { notify_error "Не удалось создать ярлык."; return; }
    chmod +x "$wrapper"
    notify_info "Ярлык создан:\n$wrapper\nЕго можно добавить в Steam как стороннюю игру."
}

open_folder() {
    local folder="$1"
    [ -d "$folder" ] || { notify_error "Папка префикса ещё не создана:\n$folder"; return; }
    if command -v xdg-open >/dev/null 2>&1; then xdg-open "$folder" >/dev/null 2>&1 &
    else notify_error "Не найден xdg-open. Папка префикса:\n$folder"; fi
}

is_managed_prefix() {
    [ "$(dirname -- "$1")" = "$COMPAT_DATA_BASE" ] && \
        [[ "$(basename -- "$1")" =~ ^multitool_[[:alnum:]_-]+$ ]]
}

backup_prefix() {
    local name="$1" prefix="$2" safe_name archive
    is_managed_prefix "$prefix" || { notify_error "Резервное копирование разрешено только для префиксов multitool внутри compatdata."; return; }
    [ -d "$prefix" ] || { notify_error "Префикс ещё не создан:\n$prefix"; return; }
    safe_name=$(printf '%s' "$name" | tr -cs '[:alnum:]_.-' '_')
    archive="$DOWNLOADS_DIR/${safe_name}_prefix_$(date +%Y%m%d_%H%M%S).tar.gz"
    if tar -czf "$archive" -C "$(dirname "$prefix")" "$(basename "$prefix")"; then
        notify_info "Резервная копия создана:\n$archive"
    else
        rm -f "$archive"; notify_error "Не удалось создать резервную копию префикса."
    fi
}

restore_prefix() {
    local name="$1" prefix="$2" archive temp
    is_managed_prefix "$prefix" || { notify_error "Восстановление разрешено только в префиксы multitool внутри compatdata."; return; }
    archive=$(zenity --file-selection --title="Выберите архив префикса для «$name»" \
        --filename="$DOWNLOADS_DIR/" --file-filter="Архивы | *.tar.gz *.tgz" 2>/dev/null) || return
    [ -f "$archive" ] || return
    if ! tar -tzf "$archive" >/dev/null 2>&1; then notify_error "Файл не является корректным архивом tar.gz."; return; fi
    if ! ask_yesno "Восстановить архив в префикс «$name»?\nТекущие файлы префикса будут заменены."; then return; fi
    temp="$CONFIG_DIR/restore_tmp"; rm -rf "$temp"; mkdir -p "$temp"
    if ! tar -xzf "$archive" -C "$temp"; then rm -rf "$temp"; notify_error "Не удалось распаковать архив."; return; fi
    # Accept only the expected prefix folder; prevent paths from being restored outside the selected prefix.
    local src
    src=$(find "$temp" -mindepth 1 -maxdepth 1 -type d -print -quit)
    if [ -z "$src" ] || [ ! -d "$src/pfx" ]; then rm -rf "$temp"; notify_error "В архиве не обнаружен Steam-совместимый префикс."; return; fi
    mkdir -p "$(dirname "$prefix")"
    rm -rf "$prefix"
    if mv "$src" "$prefix"; then rm -rf "$temp"; notify_info "Префикс восстановлен."
    else rm -rf "$temp"; notify_error "Не удалось восстановить префикс."; fi
}

check_internet() {
    local status
    command -v curl >/dev/null 2>&1 || { notify_error "Для загрузки GE-Proton требуется curl."; return 1; }
    status=$(curl -sS -L --connect-timeout 5 --max-time 12 -o /dev/null -w '%{http_code}' https://api.github.com/ 2>/dev/null) || status=""
    if [[ "$status" != 2* ]]; then
        notify_error "Нет соединения с GitHub (HTTP ${status:-нет ответа}). Проверьте подключение к интернету и повторите попытку. Загрузка не начиналась."
        return 1
    fi
    return 0
}

get_releases() {
    local json="$1"
    if command -v python3 >/dev/null 2>&1; then
        python3 -c 'import json,sys
try:
 data=json.load(open(sys.argv[1],encoding="utf-8"))
 for r in data:
  if r.get("tag_name") and not r.get("draft") and not r.get("prerelease"):
   for a in r.get("assets",[]):
    if a.get("name","").endswith(".tar.gz") and "GE-Proton" in a.get("name",""):
     print(r["tag_name"]+"\t"+a["name"]+"\t"+a["browser_download_url"])
     break
except Exception: pass' "$json"
    else
        return 1
    fi
}

download_ge_proton() {
    local json="$CONFIG_DIR/ge-releases.json" releases selected tag asset url archive temp_dir
    # This connectivity check deliberately runs before release metadata or archive downloads.
    check_internet || return
    if ! curl -fsSL --connect-timeout 8 --max-time 30 "$GE_API" -o "$json"; then
        notify_error "Не удалось получить список релизов GE-Proton с GitHub. Повторите попытку позже."
        return
    fi
    releases=$(get_releases "$json")
    if [ -z "$releases" ]; then
        notify_error "GitHub не вернул доступных архивов GE-Proton. Убедитесь, что установлен Python 3 и повторите попытку."
        return
    fi
    selected=$(printf '%s\n' "$releases" | awk -F '\t' '{print $1}' | zenity --list --title="Установить GE-Proton" \
        --text="Выберите стабильный релиз (сначала проверено соединение с GitHub)." \
        --column="Версия" --width=480 --height=420 2>/dev/null) || return
    [ -n "$selected" ] || return
    IFS=$'\t' read -r tag asset url < <(awk -F '\t' -v wanted="$selected" '$1 == wanted {print; exit}' <<< "$releases")
    [ -n "${url:-}" ] || { notify_error "Не удалось определить URL выбранного релиза."; return; }
    if ! ask_yesno "Скачать и установить $tag?\nАрхив будет загружен в Downloads, затем распакован в compatibilitytools.d."; then return; fi
    mkdir -p "$COMPAT_TOOLS_BASE" "$DOWNLOADS_DIR"
    archive="$DOWNLOADS_DIR/$asset"
    temp_dir="$COMPAT_TOOLS_BASE/.ge-install-$$"
    if ! curl -fL --retry 2 --connect-timeout 10 --max-time 0 --progress-bar "$url" -o "$archive"; then
        rm -f "$archive"; notify_error "Загрузка не удалась. Проверьте интернет и свободное место; установка не завершена."; return
    fi
    if ! tar -tzf "$archive" >/dev/null 2>&1; then
        rm -f "$archive"; notify_error "Скачанный файл не является корректным архивом. Установка отменена."; return
    fi
    rm -rf "$temp_dir"; mkdir -p "$temp_dir"
    if ! tar -xzf "$archive" -C "$temp_dir"; then
        rm -rf "$temp_dir"; notify_error "Не удалось распаковать GE-Proton."; return
    fi
    local extracted_dir
    extracted_dir=$(find "$temp_dir" -mindepth 1 -maxdepth 1 -type d -print -quit)
    if [ -z "$extracted_dir" ] || [ ! -x "$extracted_dir/proton" ]; then
        rm -rf "$temp_dir"; notify_error "Архив не содержит ожидаемый исполняемый файл Proton. Установка отменена."; return
    fi
    rm -rf "$COMPAT_TOOLS_BASE/$tag"
    if mv "$extracted_dir" "$COMPAT_TOOLS_BASE/$tag"; then
        rm -rf "$temp_dir"
        notify_info "$tag установлен в:\n$COMPAT_TOOLS_BASE/$tag\nПерезапустите Steam, чтобы Proton появился в списке. Архив сохранён: $archive"
    else
        rm -rf "$temp_dir"; notify_error "Не удалось переместить файлы GE-Proton в compatibilitytools.d."
    fi
}

manage_prefixes() {
    local -a names=()
    local name choice
    [ -d "$COMPAT_DATA_BASE" ] || { notify_info "Папка compatdata ещё не создана."; return; }
    mapfile -t names < <(library_names)
    if [ "${#names[@]}" -eq 0 ]; then notify_info "Библиотека пока пуста."; return; fi
    choice=$(printf '%s\n' "${names[@]}" | zenity --list --title="Префиксы библиотеки" \
        --text="Выберите игру, чтобы открыть её префикс, сделать резервную копию, восстановить или удалить его." \
        --column="Игра" 2>/dev/null) || return
    [ -n "$choice" ] && manage_game "$choice"
}

diagnostics() {
    local proton_count game_count name
    proton_count=$(find_proton_versions | wc -l)
    game_count=$(library_names | wc -l)
    local text="Steam Deck EXE Multitool v$VERSION\n\nБиблиотека: $game_count записей\nНайдено Proton: $proton_count\nSteam: $STEAM_ROOT\nПрефиксы: $COMPAT_DATA_BASE\nКаталог GE-Proton: $COMPAT_TOOLS_BASE\nЯрлыки: $DOWNLOADS_DIR\nЖурнал запуска: $CONFIG_DIR/launch.log\n\nПроверка компонентов:"
    for name in curl tar python3 xdg-open; do
        if command -v "$name" >/dev/null 2>&1; then text+="\n$name: установлен"; else text+="\n$name: не найден"; fi
    done
    notify_info "$text"
}

main_library