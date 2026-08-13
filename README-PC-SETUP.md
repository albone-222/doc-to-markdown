# text-extract-api на Windows + RTX 5080 — чеклист развёртывания

Материалы для запуска [CatchTheTornado/text-extract-api](https://github.com/CatchTheTornado/text-extract-api)
на ПК с Windows и RTX 5080 (Blackwell, sm_120, 16 ГБ VRAM) через Docker Desktop + WSL2.

## Почему нельзя просто `docker-compose -f docker-compose.gpu.yml up`

Три реальных дефекта апстрима, каждый ломает запуск или сильно портит опыт:

| # | Проблема | Где | Следствие |
|---|---|---|---|
| 1 | Базовый образ `nvidia/cuda:11.8.0-cudnn8-devel` и `torch --index-url .../cu118` | `dev.gpu.Dockerfile` | **Блокирующая.** Blackwell = sm_120, поддержки в CUDA 11.8 нет: `no kernel image is available for execution on the device` |
| 2 | Bind-mount `.:/app` перекрывает `/app/.dvenv` из образа; venv реально создаётся в рантайме, и оба сервиса делают это одновременно | `docker-compose.gpu.yml` + `scripts/entrypoint.sh` | Гонка при первом старте, битый venv, случайные падения celery |
| 3 | У сервиса `ollama` нет volume | `docker-compose.gpu.yml` | ~18 ГБ моделей перекачиваются заново после каждого пересоздания контейнера |

Патчи в [patches/](patches/) закрывают всё три.

## Состав материалов

```
patches/dev.gpu.Dockerfile           CUDA 12.8 + torch cu128 вместо 11.8/cu118
patches/entrypoint.sh                torch cu128 в venv, flock от гонки, PULL_MODELS, gpu-check
patches/docker-compose.blackwell.yml override: volume для ollama, driver: nvidia, OLLAMA_KEEP_ALIVE
scripts/preflight.sh                 диагностика окружения до сборки
scripts/apply-patches.sh             раскладка патчей в репозиторий (с .orig-бэкапами)
scripts/smoke-test.sh                загрузка файла + ожидание результата
```

---

## Шаг 0. Windows-хост (PowerShell)

```powershell
# Драйвер: нужна ветка 572.xx+ (Blackwell). CUDA Toolkit ставить НЕ надо.
nvidia-smi

# WSL2 актуальной версии
wsl --update
wsl --status
```

В Docker Desktop: **Settings → General → Use the WSL 2 based engine** (включено),
**Settings → Resources → WSL Integration** — включить для вашего дистрибутива Ubuntu.

> Проброс GPU в WSL2 обеспечивает Windows-драйвер. Устанавливать `nvidia-container-toolkit`
> или CUDA внутри WSL не нужно и вредно.

## Шаг 1. Клонирование (внутри WSL, не в PowerShell)

```bash
# Критично: иначе git подставит CRLF и entrypoint.sh не запустится
git config --global core.autocrlf false

# Критично: клонировать в нативную ФС WSL, НЕ в /mnt/c —
# иначе bind-mount ".:/app" пойдёт через 9p и всё будет тормозить
cd ~
git clone https://github.com/CatchTheTornado/text-extract-api.git
cd text-extract-api
```

## Шаг 2. Преflight

Скопируйте каталог с этими материалами в WSL (например в `~/tea-pc-setup`) и запустите
**из корня репозитория**:

```bash
bash ~/tea-pc-setup/scripts/preflight.sh
```

Проверяет: версию драйвера, доступность docker/compose, реальный проброс GPU в контейнер,
свободное место (нужно ≥45 ГБ), расположение каталога и переводы строк.

## Шаг 3. Патчи

```bash
bash ~/tea-pc-setup/scripts/apply-patches.sh ~/text-extract-api
```

Оригиналы сохраняются как `dev.gpu.Dockerfile.orig` и `scripts/entrypoint.sh.orig`.
Заодно создаётся `.env` из `.env.example`.

## Шаг 4. Первый запуск — только API

Поднимаем **сначала один `fastapi_app`**: он создаст venv (это ~2.5 ГБ torch) и скачает
модели. Если стартовать всё сразу, celery полезет создавать тот же venv параллельно —
flock из патча это переживёт, но ждать вслепую неудобно.

```bash
cd ~/text-extract-api
docker compose -f docker-compose.gpu.yml -f docker-compose.blackwell.yml \
  -p text-extract-api-gpu up --build fastapi_app
```

Первый старт: 10–20 мин сборка образа + 5–10 мин установка зависимостей + скачивание
моделей (~18 ГБ). Дожидаемся в логах:

```
[gpu-check] torch=2.x.x cuda=12.8 available=True
[gpu-check] device=NVIDIA GeForce RTX 5080 capability=(12, 0)
...
LLM models are ready!
```

`capability=(12, 0)` — это и есть подтверждение, что sm_120 подхватился. Если тут
`available=False` или предупреждение о неподдерживаемой архитектуре — см. «Диагностику» ниже.

Хотите урезать первую закачку — перед стартом:
```bash
export PULL_MODELS="llama3.1"   # без vision-моделей
```

## Шаг 5. Полный стек

Ctrl+C, затем:

```bash
docker compose -f docker-compose.gpu.yml -f docker-compose.blackwell.yml \
  -p text-extract-api-gpu up -d
docker compose -p text-extract-api-gpu ps
```

## Шаг 6. Проверка

```bash
bash ~/tea-pc-setup/scripts/smoke-test.sh examples/example-mri.pdf easyocr
bash ~/tea-pc-setup/scripts/smoke-test.sh examples/example-mri.pdf llama_vision llama3.2-vision
```

В соседнем окне — `watch -n1 nvidia-smi`: на первом прогоне грузится процесс python
(easyocr/torch), на втором — ollama. Если GPU простаивает, значит работа идёт на CPU.

Swagger: <http://localhost:8000/docs>

---

## Бюджет VRAM (16 ГБ)

| Модель | Размер | Влезает |
|---|---|---|
| `llama3.1:8b` (q4) | ~4.9 ГБ | да, быстро |
| `llama3.2-vision:11b` | ~7.9 ГБ | да |
| `minicpm-v` | ~5.5 ГБ | да |
| `llama3.1` + `llama3.2-vision` одновременно | ~12.8 ГБ | впритык |
| `llama3.2-vision:90b` | ~55 ГБ | нет |

`OLLAMA_KEEP_ALIVE=5m` в override выгружает простаивающую модель — при работе с двумя
моделями подряд это спасает от вытеснения. Если сценарий однопоточный и модель одна,
можно поставить `OLLAMA_KEEP_ALIVE=-1` (держать всегда) — будет быстрее.

## Диагностика

**`no kernel image is available for execution on the device`** — patch не применился либо
venv остался старый:
```bash
rm -rf ~/text-extract-api/.dvenv ~/text-extract-api/.pyproject.hash
docker compose -p text-extract-api-gpu up --build --force-recreate fastapi_app
```

**`[gpu-check] available=False`** — GPU не доехал до контейнера. Проверьте
`docker run --rm --gpus all nvidia/cuda:12.8.1-base-ubuntu22.04 nvidia-smi`.

**`$'\r': command not found` / `exec format error`** — CRLF в `entrypoint.sh`:
```bash
sed -i 's/\r$//' ~/text-extract-api/scripts/entrypoint.sh
```

**Celery молчит / задачи висят в PENDING** — воркер не поднялся:
```bash
docker compose -p text-extract-api-gpu logs --tail=100 celery_worker
```

**Всё медленно, диск шуршит** — репозиторий лежит в `/mnt/c`. Перенесите в `~`.

## Откат

```bash
cd ~/text-extract-api
docker compose -f docker-compose.gpu.yml -f docker-compose.blackwell.yml \
  -p text-extract-api-gpu down -v          # -v убьёт и volume с моделями
mv dev.gpu.Dockerfile.orig dev.gpu.Dockerfile
mv scripts/entrypoint.sh.orig scripts/entrypoint.sh
rm -f docker-compose.blackwell.yml
rm -rf .dvenv .pyproject.hash
```

## Справочник стратегий

Значения параметра `strategy` (из README апстрима): `easyocr`, `llama_vision` (значение
по умолчанию), `minicpm_v`, `remote`. Языки OCR задаются отдельно: `--language en,ru`.

## Статус проверок

Проверено с моей стороны:

- ✅ Теги `nvidia/cuda:12.8.1-cudnn-devel-ubuntu22.04` и `12.8.1-base-ubuntu22.04` существуют в Docker Hub
- ✅ `docker compose -f docker-compose.gpu.yml -f docker-compose.blackwell.yml config` — слияние корректное, все поля (volume `ollama_data`, `driver: nvidia` у всех трёх сервисов, `TORCH_INDEX_URL`, `OLLAMA_KEEP_ALIVE`) попадают в итоговый конфиг
- ✅ Синтаксис всех bash-скриптов (`bash -n`)
- ✅ Имена стратегий сверены с исходным README

Не проверено — нужен реальный запуск на вашей машине:

- ⚠️ Сборка образа и работа torch cu128 на sm_120 (у меня нет CUDA-железа, только Mac)
- ⚠️ Поведение `flock` при одновременном старте обоих сервисов
- ⚠️ Фактическая версия torch, которую подтянет pip с индекса cu128 в момент сборки

Именно поэтому в патч `entrypoint.sh` встроен блок `[gpu-check]` — он на старте печатает
версию torch, CUDA и compute capability, так что первый же лог даст однозначный ответ.
