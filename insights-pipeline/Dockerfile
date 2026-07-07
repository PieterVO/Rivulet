FROM python:3.11-slim
WORKDIR /app
COPY pyproject.toml ./
RUN pip install --no-cache-dir requests boto3
COPY insights ./insights
# Data dir is mounted at runtime: docker run -v $PWD/data:/app/data ...
ENTRYPOINT ["python", "-m", "insights"]
