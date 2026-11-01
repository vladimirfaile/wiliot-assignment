FROM python:3.12-slim

# Non-root user; no shell tools needed at runtime.
RUN useradd --uid 10001 --no-create-home app
WORKDIR /app

COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

COPY app.py .

USER 10001
EXPOSE 8000
ENV PYTHONUNBUFFERED=1
CMD ["python", "app.py"]
