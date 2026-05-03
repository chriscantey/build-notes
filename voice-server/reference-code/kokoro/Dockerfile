# Build the kokoro-tts-cpu:local base image first using the Kokoro project's
# instructions. This Dockerfile just copies our HTTP server on top of it.
FROM kokoro-tts-cpu:local

COPY server.py /app/server.py

EXPOSE 7880

CMD ["python3", "/app/server.py"]
