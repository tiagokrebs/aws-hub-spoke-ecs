import os
import socket
from fastapi import FastAPI

APP_PREFIX = os.getenv("APP_PREFIX", "")
app = FastAPI(title="Hub-Spoke ECS App")


@app.get(f"{APP_PREFIX}/")
def read_root():
    """Welcome endpoint with container information."""
    return {
        "message": "Hello from hub-spoke ECS!",
        "hostname": os.getenv("HOSTNAME", socket.gethostname()),
        "environment": os.getenv("ENVIRONMENT", "production"),
    }


@app.get(f"{APP_PREFIX}/health")
def health_check():
    """Health check endpoint for ALB target group."""
    return {"status": "healthy"}
