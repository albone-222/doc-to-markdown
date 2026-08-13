#!/usr/bin/env bash
# Копирует патчи в склонированный репозиторий text-extract-api.
# Использование:  ./scripts/apply-patches.sh /path/to/text-extract-api
#
# Оригиналы сохраняются рядом с суффиксом .orig — откат тривиален.

set -euo pipefail

REPO="${1:-}"
if [ -z "$REPO" ]; then
  echo "Использование: $0 <путь-к-склонированному-text-extract-api>" >&2
  exit 1
fi
if [ ! -f "$REPO/pyproject.toml" ] || [ ! -f "$REPO/docker-compose.gpu.yml" ]; then
  echo "Ошибка: '$REPO' не похож на репозиторий text-extract-api" >&2
  exit 1
fi

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

backup_and_copy() {
  local src="$1" dst="$2"
  if [ -f "$dst" ] && [ ! -f "$dst.orig" ]; then
    cp "$dst" "$dst.orig"
    echo "  сохранён оригинал: $(basename "$dst").orig"
  fi
  cp "$src" "$dst"
  echo "  записан: ${dst#$REPO/}"
}

echo "Применяю патчи к $REPO"
backup_and_copy "$HERE/patches/dev.gpu.Dockerfile"           "$REPO/dev.gpu.Dockerfile"
backup_and_copy "$HERE/patches/entrypoint.sh"                "$REPO/scripts/entrypoint.sh"
backup_and_copy "$HERE/patches/docker-compose.blackwell.yml" "$REPO/docker-compose.blackwell.yml"

chmod +x "$REPO/scripts/entrypoint.sh"

# Страховка от CRLF, если git всё же подставил их при клонировании
if grep -qU $'\r' "$REPO/scripts/entrypoint.sh" 2>/dev/null; then
  echo "  ! обнаружены CRLF — конвертирую в LF"
  sed -i 's/\r$//' "$REPO/scripts/entrypoint.sh"
fi

if [ ! -f "$REPO/.env" ]; then
  cp "$REPO/.env.example" "$REPO/.env"
  echo "  создан .env из .env.example"
fi

echo
echo "Готово. Запуск:"
echo "  cd $REPO"
echo "  docker compose -f docker-compose.gpu.yml -f docker-compose.blackwell.yml -p text-extract-api-gpu up --build fastapi_app"
