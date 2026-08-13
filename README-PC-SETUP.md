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
свободное место (нужно ≥45 ГБ), расположение каталога, переводы строк и применены ли патчи.

> **Скрипт ничего не меняет — только диагностирует.** Успешный preflight не означает,
> что репозиторий готов к сборке: патчи накладывает отдельный скрипт из шага 3.

## Шаг 3. Патчи (обязательно)

```bash
bash ~/tea-pc-setup/scripts/apply-patches.sh ~/text-extract-api
```

Без этого шага файла `docker-compose.blackwell.yml` в репозитории нет, и команда запуска
из шага 4 упадёт с `no such file or directory`. Проверить результат:

```bash
cd ~/text-extract-api
ls -l docker-compose.blackwell.yml .env dev.gpu.Dockerfile.orig
head -3 dev.gpu.Dockerfile     # первая строка: "# ПАТЧ для RTX 5080 (Blackwell, sm_120)"
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
bash ~/tea-pc-setup/scripts/smoke-test.sh examples/example-mri.pdf minicpm_v minicpm-v
```

> Стратегию `llama_vision` использовать нельзя — см. «Регрессия Ollama» ниже.

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

## Регрессия Ollama: `llama_vision` не работает

Симптом — задача падает, в логах celery:

```
llama-server process has terminated: exit status 1:
error loading model: unknown model architecture: 'mllama'
```

Причина не в этой сборке и не в GPU. Поддержка архитектуры `mllama` (Llama 3.2 Vision)
жила в приватном форке llama.cpp внутри Ollama и в апстрим никогда не уходила. При
переходе на новый движок в **v0.30.0** патчи не перенесли, в mainline llama.cpp этой
архитектуры не было никогда.

| Версия образа | Дата | `mllama` |
|---|---|---|
| `0.24.0` | 14 мая 2026 | работает |
| **`0.30.0`** | **1 июня 2026** | **удалена** |
| `0.32.9` | 11 августа 2026 | нет |

[ollama/ollama#16490](https://github.com/ollama/ollama/issues/16490) открыт с 4 июня 2026,
не исправлен. В `docker-compose.gpu.yml` стоит `image: ollama/ollama` + `pull_policy: always`,
то есть всегда подтягивается свежая версия — попасть на рабочую невозможно без явного пина.

**Решение в этой сборке:** vision-стратегия — `minicpm_v`. Она использует тот же класс
`OllamaStrategy`, отличается только моделью:

```yaml
minicpm_v:
   class: text_extract_api.extract.strategies.ollama.OllamaStrategy
   model: minicpm-v
```

Поэтому переход не требует изменений кода — достаточно передать `strategy=minicpm_v`.
`llama3.2-vision` убрана из `PULL_MODELS`, это экономит 7.9 ГБ закачки.

Если llama3.2-vision нужна принципиально — закрепите старый образ в
`docker-compose.blackwell.yml`:
```yaml
  ollama:
    image: ollama/ollama:0.24.0
    pull_policy: missing
```
Ценой трёх месяцев исправлений и новых моделей.

### Сопутствующий баг апстрима

В [strategies/ollama.py](https://github.com/CatchTheTornado/text-extract-api/blob/main/text_extract_api/extract/strategies/ollama.py)
импортируется только `Client`, а локальная переменная называется `ollama`, поэтому
`except ollama.ResponseError` сам падает с `AttributeError` и прячет настоящее сообщение
сервера. `apply-patches.sh` чинит это точечно (`from ollama import Client, ResponseError`
+ `except ResponseError`), идемпотентно и только при точном совпадении строк.

## Справочник стратегий

| `strategy` | Модель | Статус |
|---|---|---|
| `easyocr` | — (PyTorch OCR) | работает |
| `minicpm_v` | `minicpm-v` | работает, рекомендуемая vision |
| `docling` | `llama3.1` | работает |
| `llama_vision` | `llama3.2-vision` | **сломана** (см. выше), значение по умолчанию в апстриме |
| `remote` | marker-pdf | нужен внешний сервер |

Языки OCR задаются отдельно: `--language en,ru`.

## Статус проверок

Подтверждено на живом железе (RTX 5080, Windows + WSL2, Docker Desktop):

- ✅ **Образ собирается, torch видит карту.** Лог `[gpu-check]` при старте:
  ```
  [gpu-check] torch=2.11.0+cu128 cuda=12.8 available=True
  [gpu-check] device=NVIDIA GeForce RTX 5080 capability=(12, 0)
  ```
  `capability=(12, 0)` = sm_120. На апстримном `dev.gpu.Dockerfile` (CUDA 11.8 / cu118)
  здесь была бы ошибка `no kernel image is available for execution on the device`.
- ✅ pip с индекса cu128 подтянул `torch 2.11.0+cu128` под cp310 и стек `nvidia-*-cu12 12.8.x`
- ✅ `apply-patches.sh` раскладывает файлы, делает `.orig`-бэкапы и создаёт `.env`
- ✅ `preflight.sh` корректно различает пропатченный и непропатченный репозиторий

Проверено статически:

- ✅ Теги `nvidia/cuda:12.8.1-cudnn-devel-ubuntu22.04` и `12.8.1-base-ubuntu22.04` существуют в Docker Hub
- ✅ `docker compose -f docker-compose.gpu.yml -f docker-compose.blackwell.yml config` — слияние корректное, все поля (volume `ollama_data`, `driver: nvidia` у всех трёх сервисов, `TORCH_INDEX_URL`, `OLLAMA_KEEP_ALIVE`) попадают в итоговый конфиг
- ✅ Синтаксис всех bash-скриптов (`bash -n`)
- ✅ Имена стратегий сверены с исходным README

Остаётся непроверенным:

- ⚠️ Поведение `flock` при одновременном старте `fastapi_app` и `celery_worker`
  (первый запуск шёл по чеклисту — сначала только `fastapi_app`)
- ⚠️ Фактическая скорость OCR на разных стратегиях

Блок `[gpu-check]` печатает версию torch, CUDA и compute capability при каждом старте —
если что-то поедет после обновления зависимостей, это станет видно сразу.
