FROM python:3.11-slim
ENV PYTHONDONTWRITEBYTECODE=1 PYTHONUNBUFFERED=1
WORKDIR /srv
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY app ./app
RUN useradd -m app && chown -R app /srv
USER app
CMD exec uvicorn app.main:app_factory --factory --host 0.0.0.0 --port ${PORT:-8080}
