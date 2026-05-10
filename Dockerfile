FROM python:3.11-slim

ENV PYTHONDONTWRITEBYTECODE=1 \
    PYTHONUNBUFFERED=1 \
    PIP_NO_CACHE_DIR=1 \
    POETRY_VIRTUALENVS_CREATE=false \
    POETRY_NO_INTERACTION=1

WORKDIR /app

RUN apt-get update \
    && apt-get install -y --no-install-recommends gcc libpq-dev \
    && rm -rf /var/lib/apt/lists/* \
    && pip install --upgrade pip \
    && pip install poetry==1.8.3

COPY pyproject.toml poetry.lock ./
RUN poetry install --only main --no-root

COPY app ./app
COPY application.py ./

EXPOSE 5000

CMD ["gunicorn", "--preload", "--bind", "0.0.0.0:5000", "--workers", "2", "--timeout", "60", "application:application"]
