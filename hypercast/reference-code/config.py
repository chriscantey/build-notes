"""Centralized config. Everything reads from environment variables with sane
defaults, so there's nothing personal to sanitize — point your .env at this.
"""
from dotenv import load_dotenv
load_dotenv()

import os
from pathlib import Path

# Request and content limits.
MAX_REQUEST_SIZE = 1 * 1024 * 1024       # 1 MB request body limit
MAX_URL_LENGTH = 2048                    # Standard browser URL limit
MAX_INPUT_SIZE = 100 * 1024              # 100 KB for direct text input
MAX_CONTENT_INFLATION = 1.1              # Max growth from optional LLM cleanup pass

# Server.
SERVER_HOST = '0.0.0.0'
SERVER_PORT = int(os.getenv('SERVER_PORT', '4973'))
FLASK_DEBUG = os.getenv('FLASK_DEBUG', '').lower() == 'true'

# Single shared API key. Generate with: openssl rand -hex 32
API_KEY = os.getenv('API_KEY') or os.getenv('API_TOKEN')
if not API_KEY:
    raise ValueError("API_KEY must be set in environment")

# Feed.
BASE_URL = os.getenv('BASE_URL', 'http://localhost:4973')
FEED_TITLE = os.getenv('FEED_TITLE', 'Hypercast')
FEED_DESCRIPTION = os.getenv('FEED_DESCRIPTION', 'Personal podcast of articles I wanted to listen to.')
FEED_IMAGE = os.getenv('FEED_IMAGE', 'podcast-cover.png')
FEED_SOUND = os.getenv('FEED_SOUND', 'intro-sound.mp3')
FEED_LANGUAGE = 'en-us'

# Paths (relative to the app root inside the container).
APP_ROOT = Path(__file__).parent.parent
STATIC_PATH = APP_ROOT / 'app' / 'static'
AUDIO_PATH = STATIC_PATH / 'audio'
ASSETS_PATH = APP_ROOT / 'assets'
INTRO_SOUND_PATH = ASSETS_PATH / FEED_SOUND

# Audio output.
AUDIO_OUTPUT_FORMAT = 'mp3'
AUDIO_OUTPUT_QUALITY = '192k'

# TTS provider config.
OPENAI_API_KEY = os.getenv('OPENAI_API_KEY')
GOOGLE_API_KEY = os.getenv('GOOGLE_API_KEY')
TTS_MODEL = os.getenv('TTS_MODEL', 'tts-1-hd')
TTS_VOICE = os.getenv('TTS_VOICE', 'onyx')
TTS_SPEED = float(os.getenv('TTS_SPEED', '1.0'))

# Content provider: ollama (default), openai, gemini.
CONTENT_PROVIDER = os.getenv('CONTENT_PROVIDER', 'ollama')
CONTENT_MODEL_OPENAI = os.getenv('CONTENT_MODEL_OPENAI', 'gpt-4o-mini')
CONTENT_MODEL_GEMINI = os.getenv('CONTENT_MODEL_GEMINI', 'gemini-2.0-flash')
CONTENT_MODEL_OLLAMA = os.getenv('CONTENT_MODEL_OLLAMA', 'qwen3:8b')
OLLAMA_BASE_URL = os.getenv('OLLAMA_BASE_URL', 'http://localhost:11434')

# Optional LLM cleanup pass after deterministic extraction. Off by default.
CONTENT_CLEANUP_LLM = os.getenv('CONTENT_CLEANUP_LLM', 'false').lower() == 'true'
CONTENT_CLEANUP_MODEL = os.getenv('CONTENT_CLEANUP_MODEL', 'gpt-4o-mini')
TITLE_GENERATION_MODEL = os.getenv('TITLE_GENERATION_MODEL', 'gpt-4o-mini')
