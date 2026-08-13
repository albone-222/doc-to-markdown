#!/bin/bash
# ПАТЧ для RTX 5080 (Blackwell) + устранение гонки между fastapi_app и celery_worker.
#
# Что исправлено против оригинала:
#  1. torch ставится с индекса cu128 ДО "pip install ." — иначе pip может вытянуть
#     сборку под cu124 и старее, которая не знает sm_120 (архитектура RTX 50xx).
#  2. flock вокруг создания .dvenv: оба сервиса монтируют один и тот же каталог
#     (".:/app") и в оригинале одновременно создают venv, ломая его друг другу.
#  3. Список моделей вынесен в PULL_MODELS. llama3.2-vision ИСКЛЮЧЕНА: Ollama 0.30.0
#     удалила поддержку архитектуры mllama, модель не загружается ни в какой версии
#     начиная с 1 июня 2026 (ollama/ollama#16490). Вместо неё minicpm-v — та же
#     стратегия OllamaStrategy, другая модель. Экономит 7.9 ГБ закачки.

TORCH_INDEX_URL="${TORCH_INDEX_URL:-https://download.pytorch.org/whl/cu128}"
PULL_MODELS="${PULL_MODELS:-llama3.1 minicpm-v}"

PYPROJECT_HASH_FILE=".pyproject.hash"
CURRENT_HASH=$(sha256sum pyproject.toml | awk '{ print $1 }')

# --- Секция установки зависимостей: только один контейнер за раз ---------------
exec 9>/app/.dvenv.lock
echo "Ожидание блокировки на .dvenv ..."
flock 9

if [ ! -d ".dvenv" ] || [ ! -f "$PYPROJECT_HASH_FILE" ] || [ "$(cat $PYPROJECT_HASH_FILE)" != "$CURRENT_HASH" ]; then
   echo "Зависимости изменились или .dvenv отсутствует. Переустановка..."
   python -m venv .dvenv
   source .dvenv/bin/activate
   pip install --upgrade pip setuptools

   echo "Установка torch под CUDA (index: $TORCH_INDEX_URL) ..."
   pip install --no-cache-dir torch torchvision --index-url "$TORCH_INDEX_URL"

   pip install .
   echo "$CURRENT_HASH" >"$PYPROJECT_HASH_FILE"
else
   python3 -m venv --upgrade /app/.dvenv # temporary :(
   echo "Виртуальное окружение актуально."
fi

flock -u 9
exec 9>&-
# -----------------------------------------------------------------------------

source .dvenv/bin/activate

# Диагностика: видит ли torch именно нашу карту. При sm_120 и старом torch
# здесь будет предупреждение о неподдерживаемой compute capability.
python - <<'PY'
try:
    import torch
    print(f"[gpu-check] torch={torch.__version__} cuda={torch.version.cuda} available={torch.cuda.is_available()}")
    if torch.cuda.is_available():
        print(f"[gpu-check] device={torch.cuda.get_device_name(0)} capability={torch.cuda.get_device_capability(0)}")
except Exception as e:
    print(f"[gpu-check] недоступно: {e}")
PY

if [ "$APP_TYPE" = "celery" ]; then
   echo "Starting Celery worker..."
   exec celery -A text_extract_api.celery_app worker --loglevel=info --pool=solo
else
   echo "Pulling LLM models ($PULL_MODELS), please wait until this process is done..."
   for m in $PULL_MODELS; do
      echo "  -> $m"
      python client/cli.py llm_pull --model "$m"
   done
   echo "LLM models are ready!"

   echo "Starting FastAPI app..."

   if [ "$APP_ENV" = "production" ]; then
      exec uvicorn text_extract_api.main:app --host 0.0.0.0 --port 8000
   else
      exec uvicorn text_extract_api.main:app --host 0.0.0.0 --port 8000 --reload
   fi
fi
