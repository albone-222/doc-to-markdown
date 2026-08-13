#!/usr/bin/env bash
# Проверка живого сервиса: заливает файл, дожидается результата, печатает Markdown.
# Использование:
#   ./scripts/smoke-test.sh <файл.pdf> [strategy] [model]
# Примеры:
#   ./scripts/smoke-test.sh examples/example-mri.pdf easyocr
#   ./scripts/smoke-test.sh examples/example-mri.pdf llama_vision llama3.2-vision
#
# Параллельно полезно смотреть в другом окне:  watch -n1 nvidia-smi

set -uo pipefail

FILE="${1:-}"
STRATEGY="${2:-easyocr}"
MODEL="${3:-}"
BASE="${BASE_URL:-http://localhost:8000}"
TIMEOUT="${TIMEOUT:-900}"

if [ -z "$FILE" ] || [ ! -f "$FILE" ]; then
  echo "Использование: $0 <файл.pdf|png|jpg> [strategy] [model]" >&2
  exit 1
fi

echo "== Проверка доступности $BASE =="
if ! curl -sSf --max-time 5 "$BASE/docs" -o /dev/null; then
  echo "Сервис не отвечает на $BASE. Контейнер fastapi_app поднят?" >&2
  exit 1
fi
echo "OK"

echo
echo "== Загрузка '$FILE' (strategy=$STRATEGY, model='${MODEL:-—}') =="
RESP=$(curl -sS -X POST \
  -F "file=@${FILE}" \
  -F "strategy=${STRATEGY}" \
  -F "ocr_cache=true" \
  -F "prompt=" \
  -F "model=${MODEL}" \
  "$BASE/ocr/upload")

TASK_ID=$(printf '%s' "$RESP" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("task_id",""))' 2>/dev/null)

if [ -z "$TASK_ID" ]; then
  echo "Не удалось получить task_id. Ответ сервера:" >&2
  printf '%s\n' "$RESP" >&2
  exit 1
fi
echo "task_id: $TASK_ID"

echo
echo "== Ожидание результата (таймаут ${TIMEOUT}с) =="
START=$SECONDS
while :; do
  R=$(curl -sS "$BASE/ocr/result/$TASK_ID")
  STATE=$(printf '%s' "$R" | python3 -c 'import sys,json; print(json.load(sys.stdin).get("state",""))' 2>/dev/null)
  INFO=$(printf '%s' "$R" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("status") or "")' 2>/dev/null)

  printf '\r  [%4dс] state=%-10s %s' "$((SECONDS-START))" "${STATE:-?}" "${INFO:0:60}"

  case "$STATE" in
    SUCCESS)
      echo; echo
      echo "== Результат =="
      printf '%s' "$R" | python3 -c 'import sys,json; d=json.load(sys.stdin); print(d.get("result") or json.dumps(d, ensure_ascii=False, indent=2))'
      exit 0
      ;;
    FAILURE)
      echo; echo "ЗАДАЧА УПАЛА. Полный ответ:" >&2
      printf '%s\n' "$R" >&2
      echo "Логи: docker compose -p text-extract-api-gpu logs --tail=100 celery_worker" >&2
      exit 1
      ;;
  esac

  if [ $((SECONDS-START)) -ge "$TIMEOUT" ]; then
    echo; echo "Таймаут. Последний ответ:" >&2
    printf '%s\n' "$R" >&2
    exit 1
  fi
  sleep 3
done
