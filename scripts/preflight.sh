#!/usr/bin/env bash
# Проверка готовности окружения ПЕРЕД сборкой. Запускать внутри WSL2 (Ubuntu).
# Ничего не устанавливает и не меняет — только диагностика.

set -uo pipefail

FAIL=0
ok()   { printf '  \033[32m[OK]\033[0m   %s\n' "$1"; }
warn() { printf '  \033[33m[WARN]\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m[FAIL]\033[0m %s\n' "$1"; FAIL=1; }

echo "=== 1. Драйвер NVIDIA (проброс из Windows) ==="
if command -v nvidia-smi >/dev/null 2>&1; then
  DRV=$(nvidia-smi --query-gpu=driver_version --format=csv,noheader 2>/dev/null | head -1)
  GPU=$(nvidia-smi --query-gpu=name --format=csv,noheader 2>/dev/null | head -1)
  VRAM=$(nvidia-smi --query-gpu=memory.total --format=csv,noheader 2>/dev/null | head -1)
  if [ -n "$DRV" ]; then
    ok "GPU: $GPU, VRAM: $VRAM, драйвер: $DRV"
    # Blackwell (RTX 50xx) требует ветку 570+/572+
    MAJOR=${DRV%%.*}
    if [ "${MAJOR:-0}" -lt 570 ] 2>/dev/null; then
      bad "Драйвер $DRV слишком старый для Blackwell. Нужен 572.xx+ (Windows). Обновите через GeForce Experience / nvidia.com."
    else
      ok "Версия драйвера подходит для RTX 50xx"
    fi
  else
    bad "nvidia-smi есть, но не отвечает — проброс GPU в WSL не работает"
  fi
else
  bad "nvidia-smi не найден. В WSL2 он приходит с Windows-драйвером; CUDA Toolkit внутри WSL ставить НЕ нужно."
fi

echo
echo "=== 2. Docker ==="
if command -v docker >/dev/null 2>&1; then
  ok "docker: $(docker --version)"
  if docker compose version >/dev/null 2>&1; then
    ok "compose: $(docker compose version --short)"
  else
    bad "docker compose (v2) не найден — включите Docker Desktop с WSL2 backend"
  fi
  if docker info >/dev/null 2>&1; then
    ok "демон доступен"
  else
    bad "демон недоступен: запустите Docker Desktop и включите интеграцию с этим WSL-дистрибутивом"
  fi
else
  bad "docker не найден в WSL. Docker Desktop → Settings → Resources → WSL Integration"
fi

echo
echo "=== 3. Проброс GPU в контейнер ==="
if docker info >/dev/null 2>&1; then
  if docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu22.04 nvidia-smi -L 2>/dev/null; then
    ok "GPU виден внутри контейнера"
  else
    bad "Контейнер не видит GPU. Проверьте Docker Desktop → Settings → General → 'Use the WSL 2 based engine'"
  fi
else
  warn "пропущено — демон недоступен"
fi

echo
echo "=== 4. Файловая система и место на диске ==="
CWD=$(pwd -P)
case "$CWD" in
  /mnt/*) bad "Текущий каталог '$CWD' лежит на диске Windows. Bind-mount '.:/app' через 9p будет крайне медленным — клонируйте в \$HOME внутри WSL." ;;
  *)      ok "Каталог '$CWD' в нативной ФС WSL" ;;
esac

AVAIL_GB=$(df -BG --output=avail . 2>/dev/null | tail -1 | tr -dc '0-9')
if [ -n "${AVAIL_GB:-}" ]; then
  if [ "$AVAIL_GB" -ge 45 ]; then
    ok "Свободно ${AVAIL_GB} ГБ (нужно ~40: образы + torch + ~18 ГБ моделей)"
  else
    bad "Свободно всего ${AVAIL_GB} ГБ. Нужно минимум 45 ГБ."
  fi
fi

echo
echo "=== 5. Переводы строк (классические грабли на Windows) ==="
if [ -f scripts/entrypoint.sh ]; then
  if grep -qU $'\r' scripts/entrypoint.sh 2>/dev/null; then
    bad "scripts/entrypoint.sh содержит CRLF — контейнер упадёт с 'exec format error' / '\\r: command not found'. Исправьте: git config --global core.autocrlf false && rm -rf <repo> && клонировать заново"
  else
    ok "scripts/entrypoint.sh в LF"
  fi
else
  warn "scripts/entrypoint.sh не найден — запустите скрипт из корня склонированного репозитория"
fi

echo
echo "=== 6. Статус патчей (шаг 3 чеклиста) ==="
PATCHED=1
[ -f docker-compose.blackwell.yml ] || { PATCHED=0; warn "нет docker-compose.blackwell.yml"; }
[ -f .env ]                        || { PATCHED=0; warn "нет .env (есть только .env.example)"; }
if [ -f dev.gpu.Dockerfile ] && grep -q 'cu128' dev.gpu.Dockerfile 2>/dev/null; then
  :
else
  PATCHED=0
  warn "dev.gpu.Dockerfile всё ещё под CUDA 11.8 / cu118 — на RTX 50xx работать не будет"
fi

if [ "$PATCHED" -eq 1 ]; then
  ok "Патчи применены, можно собирать"
else
  echo
  echo "  Патчи ещё НЕ применены. preflight.sh только диагностирует и ничего не меняет."
  echo "  Выполните:  bash <каталог-материалов>/scripts/apply-patches.sh \$(pwd)"
  echo "  Команда 'docker compose -f docker-compose.gpu.yml -f docker-compose.blackwell.yml'"
  echo "  до этого работать не будет — второго файла просто нет на диске."
fi

echo
if [ "$FAIL" -eq 0 ]; then
  if [ "$PATCHED" -eq 1 ]; then
    echo "Готово: препятствий не найдено, окружение готово к сборке."
  else
    echo "Окружение в порядке, но сначала примените патчи (шаг 3)."
  fi
else
  echo "Есть блокирующие проблемы — устраните их до сборки."
fi
exit "$FAIL"
