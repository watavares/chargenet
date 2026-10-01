FROM python:3.13-slim

WORKDIR /app
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt
COPY simulator.py .

# Never run as root inside the container
USER nobody
CMD ["python", "simulator.py"]
