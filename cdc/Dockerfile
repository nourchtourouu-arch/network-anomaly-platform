# ── CDC Pipeline Dockerfile ────────────────────────────────────────────────
FROM python:3.12-slim

# Set working directory
WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code
COPY cdc_pipeline.py .

# Run the CDC pipeline
CMD ["python", "cdc_pipeline.py"]