# ── Generator Service Dockerfile ──────────────────────────────────────────
FROM python:3.12-slim

# Set working directory
WORKDIR /app

# Install dependencies
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy source code
COPY log_generator.py .

# Run the generator
CMD ["python", "log_generator.py"]