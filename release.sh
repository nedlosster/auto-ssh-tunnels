#!/bin/bash
# Сборка пакетов и публикация GitHub release
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
VERSION_FILE="$SCRIPT_DIR/packaging/VERSION"
VERSION="$(cat "$VERSION_FILE" | tr -d '[:space:]')"
BUILD_SH="$SCRIPT_DIR/packaging/build.sh"
OUT_DIR="$SCRIPT_DIR/packaging/_out"

DRY_RUN=0

usage() {
    cat <<EOF
Использование: $0 [-d] [-h] <команда>

Команды:
  build          Собрать пакеты (deb, rpm при наличии rpmbuild)
  publish        build + git tag + gh release create
  bump X.Y.Z     Обновить версию в packaging/VERSION

Опции:
  -d    Dry-run: показать действия без выполнения
  -h    Справка
EOF
    exit 0
}

log() { echo "==> $*"; }

run() {
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] $*"
    else
        "$@"
    fi
}

# --- build ---
cmd_build() {
    log "Сборка пакетов v${VERSION}"

    run bash "$BUILD_SH" clean
    run bash "$BUILD_SH" deb

    if command -v rpmbuild &>/dev/null; then
        run bash "$BUILD_SH" rpm
    else
        log "rpmbuild не найден, rpm пропущен"
    fi

    log "Артефакты:"
    ls "$OUT_DIR"/ 2>/dev/null || echo "(пусто -- dry-run)"
}

# --- publish ---
cmd_publish() {
    local tag="v${VERSION}"

    # Проверка чистого working tree
    if [[ -n "$(git -C "$SCRIPT_DIR" status --porcelain --untracked-files=no)" ]]; then
        echo "ОШИБКА: working tree не чист. Закоммитьте изменения." >&2
        exit 1
    fi

    # Проверка отсутствия тега
    if git -C "$SCRIPT_DIR" rev-parse "$tag" &>/dev/null; then
        echo "ОШИБКА: тег $tag уже существует." >&2
        exit 1
    fi

    # Сборка
    cmd_build

    # Тег
    log "Создание тега $tag"
    run git -C "$SCRIPT_DIR" tag -a "$tag" -m "Release $tag"

    # Push
    log "Push master + tags"
    run git -C "$SCRIPT_DIR" push origin master --tags

    # Сбор артефактов
    local assets=()
    for f in "$OUT_DIR"/*.deb "$OUT_DIR"/*.rpm; do
        [[ -f "$f" ]] && assets+=("$f")
    done

    if [[ ${#assets[@]} -eq 0 && "$DRY_RUN" -eq 0 ]]; then
        echo "ОШИБКА: нет артефактов для загрузки." >&2
        exit 1
    fi

    # GitHub release
    log "Создание GitHub release $tag"
    if [[ "$DRY_RUN" -eq 1 ]]; then
        echo "[dry-run] gh release create $tag ${assets[*]:-} --title $tag --generate-notes"
    else
        gh release create "$tag" "${assets[@]}" \
            --title "$tag" \
            --generate-notes
    fi

    log "Релиз $tag опубликован"
}

# --- bump ---
cmd_bump() {
    local new_version="$1"

    if [[ ! "$new_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "ОШИБКА: версия должна быть в формате X.Y.Z" >&2
        exit 1
    fi

    log "Обновление версии: $VERSION -> $new_version"
    run bash -c "echo '$new_version' > '$VERSION_FILE'"
    log "packaging/VERSION = $new_version"
}

# --- Разбор опций ---
while getopts "dh" opt; do
    case "$opt" in
        d) DRY_RUN=1 ;;
        h) usage ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))

COMMAND="${1:-}"
shift || true

case "$COMMAND" in
    build)   cmd_build ;;
    publish) cmd_publish ;;
    bump)    cmd_bump "${1:?Укажите версию: release.sh bump X.Y.Z}" ;;
    *)       usage ;;
esac
