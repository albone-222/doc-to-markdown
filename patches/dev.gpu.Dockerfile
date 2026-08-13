# ПАТЧ для RTX 5080 (Blackwell, sm_120)
# Оригинал репозитория собран под CUDA 11.8 + torch cu118 — на Blackwell не работает
# (ошибка "no kernel image is available for execution on the device").
# Изменено: базовый образ CUDA 12.8 и torch с индекса cu128.

ARG CUDA_VERSION="12.8.1"
ARG UBUNTU_VERSION="22.04"
ARG MAX_JOBS=4

# Для CUDA >= 12.3 в теге образа больше нет номера версии cuDNN: просто "-cudnn-devel-".
FROM nvidia/cuda:${CUDA_VERSION}-cudnn-devel-ubuntu${UBUNTU_VERSION}

RUN mkdir -p /app/storage && ln -s /storage /app/storage # backward compatibility for (https://github.com/CatchTheTornado/text-extract-api/issues/85)

RUN apt-get update && \
    apt-get install -y --no-install-recommends \
    wget \
    curl \
    unzip \
    git \
    python3 \
    python3-pip \
    python3-venv \
    libgl1 \
    libglib2.0-0 \
    libglib2.0-dev \
    gnupg2 \
    ca-certificates \
    apt-transport-https \
    software-properties-common \
    libreoffice \
    libmagic1 \
    libmagic-dev \
    ffmpeg \
    git-lfs \
    xvfb \
    util-linux \
    && ln -s /usr/bin/python3 /usr/bin/python \
    && apt-get install -y python3-packaging \
    && rm -rf /var/lib/apt/lists/*

# Blackwell требует CUDA 12.8+. Ставим системно — как страховка/прогрев кэша;
# фактическая рабочая копия torch ставится в /app/.dvenv из entrypoint.sh,
# потому что bind-mount ".:/app" перекрывает всё, что собрано здесь.
RUN pip3 install --no-cache-dir torch torchvision torchaudio --index-url https://download.pytorch.org/whl/cu128

WORKDIR /app

RUN echo 'Acquire::http::Pipeline-Depth 0;\nAcquire::http::No-Cache true;\nAcquire::BrokenProxy true;\n' > /etc/apt/apt.conf.d/99fixbadproxy

RUN apt-get clean && rm -rf /var/lib/apt/lists/* \
    && apt-get update --fix-missing \
    && apt-get install -y \
        libgl1 \
        poppler-utils \
        libpoppler-cpp-dev \
    && rm -rf /var/lib/apt/lists/*

WORKDIR /app

EXPOSE 8000

ENTRYPOINT ["/app/scripts/entrypoint.sh"]
