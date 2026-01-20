FROM public.ecr.aws/docker/library/python:3.11-slim

WORKDIR /app

# Install dependencies first for better layer caching.
COPY requirements.txt .
RUN pip install --no-cache-dir -r requirements.txt

# Copy the application.
COPY server.py .

# AgentCore Runtime expects the MCP server on 0.0.0.0:8000/mcp.
EXPOSE 8000

CMD ["python", "server.py"]
