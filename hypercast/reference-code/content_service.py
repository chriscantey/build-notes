"""Content extraction and LLM helpers.

Pipeline:
  validate_input        -> URL detection, size checks, fetch + Readability
  fetch_url_content     -> requests.get with a browser User-Agent
  extract_with_readability -> shells out to Bun running @mozilla/readability
  generate_with_ollama  -> native /api/chat with `think: false` to suppress qwen3 thinking tokens
  process_validated_input -> assemble title, summary, voice, prepend header

The optional clean_text_with_llm pass is included for completeness but is
disabled by default (CONTENT_CLEANUP_LLM=false). The deterministic
extraction is sufficient for almost all real-world pages.

[Trimmed for brevity:
  - Full BoilerplatePatterns regex (~40 patterns, see clean_html_content)
  - Full _BOILERPLATE_LINE_PATTERNS regex (~30 patterns)
  Both are deterministic content-cleanup patterns; not load-bearing for the
  pipeline shape. See the project source for the complete list.]
"""
import requests
import logging
import re
import sys
import json
import subprocess
import os
from datetime import datetime, timezone
from dotenv import load_dotenv
from config.config import (
    CONTENT_PROVIDER,
    CONTENT_MODEL_OPENAI,
    CONTENT_MODEL_GEMINI,
    CONTENT_MODEL_OLLAMA,
    OLLAMA_BASE_URL,
    GOOGLE_API_KEY,
)
from .database_service import db

logger = logging.getLogger(__name__)
load_dotenv()

from openai import OpenAI
openai_client = OpenAI()

# Lazy-init Gemini.
_genai_client = None


def _get_genai_client():
    global _genai_client
    if _genai_client is None:
        from google import genai
        _genai_client = genai.Client(api_key=GOOGLE_API_KEY)
    return _genai_client


# ---------- LLM provider helpers ----------

def generate_with_gemini(system_prompt, user_content, temperature=0.3, max_tokens=None):
    from google.genai import types

    client = _get_genai_client()
    full_content = f"{system_prompt}\n\n{user_content}"
    config_kwargs = {"temperature": temperature}
    if max_tokens:
        config_kwargs["max_output_tokens"] = max_tokens

    response = client.models.generate_content(
        model=CONTENT_MODEL_GEMINI,
        contents=full_content,
        config=types.GenerateContentConfig(**config_kwargs),
    )
    return response.text.strip()


def generate_with_ollama(system_prompt, user_content, temperature=0.3, max_tokens=None):
    """Native Ollama /api/chat with think:false.

    Why not the OpenAI-compatible /v1/ endpoint: qwen3 emits <think>...</think>
    blocks that leak through the OpenAI-compatible path. The native endpoint
    accepts `think: false` and suppresses them entirely.

    num_gpu=0 forces CPU. Title and summary calls are tiny — CPU is plenty
    fast — and avoids competing for VRAM with Chatterbox TTS.
    """
    payload = {
        "model": CONTENT_MODEL_OLLAMA,
        "messages": [
            {"role": "system", "content": system_prompt},
            {"role": "user", "content": user_content},
        ],
        "stream": False,
        "think": False,
        "keep_alive": "5m",
        "options": {"temperature": temperature, "num_gpu": 0},
    }
    if max_tokens:
        payload["options"]["num_predict"] = max_tokens

    try:
        response = requests.post(
            f"{OLLAMA_BASE_URL}/api/chat",
            json=payload,
            timeout=120,
        )
        response.raise_for_status()
        return response.json()["message"]["content"].strip()
    except requests.RequestException as e:
        logger.error(f"Ollama API error: {e}")
        raise


# ---------- URL handling ----------

_URL_PATTERN = re.compile(
    r'^https?://'
    r'(?:(?:[A-Z0-9](?:[A-Z0-9-]{0,61}[A-Z0-9])?\.)+[A-Z]{2,6}\.?|'
    r'localhost|'
    r'\d{1,3}\.\d{1,3}\.\d{1,3}\.\d{1,3})'
    r'(?::\d+)?'
    r'(?:/?|[/?]\S+)$',
    re.IGNORECASE,
)


def is_url(text):
    return _URL_PATTERN.match(text) is not None


def fetch_url_content(url):
    """Fetch raw HTML with a desktop browser User-Agent."""
    headers = {
        'User-Agent': (
            'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 '
            '(KHTML, like Gecko) Chrome/120.0.0.0 Safari/537.36'
        )
    }
    response = requests.get(url, headers=headers)
    response.raise_for_status()
    return response.text


# Path to the Bun extraction script.
_READABILITY_SCRIPT = os.path.join(
    os.path.dirname(os.path.abspath(__file__)),
    '..', '..', 'readability', 'extract.js',
)


def extract_with_readability(html, url=None):
    """Shell out to Bun running @mozilla/readability.

    Returns dict with title, byline, textContent, excerpt — or None on failure.
    The 100-char floor catches pages where Readability returned a fragment
    (paywall, JavaScript-only rendering, etc.) so the fallback path can run.
    """
    try:
        cmd = ['bun', _READABILITY_SCRIPT]
        if url:
            cmd.extend(['--url', url])

        result = subprocess.run(
            cmd,
            input=html.encode('utf-8'),
            capture_output=True,
            timeout=30,
        )

        if result.returncode != 0:
            logger.error(f'Readability subprocess exited non-zero: '
                         f'{result.stderr.decode("utf-8", errors="replace")}')
            return None

        output = json.loads(result.stdout.decode('utf-8'))
        if output.get('error'):
            logger.warning(f'Readability error: {output["error"]}')
            return None

        if len(output.get('textContent', '').strip()) < 100:
            logger.warning('Readability extracted too little content')
            return None

        return output

    except subprocess.TimeoutExpired:
        logger.error('Readability extraction timed out after 30s')
        return None
    except Exception as e:
        logger.error(f'Readability error: {e}')
        return None


MAX_URL_LENGTH = 2048
MAX_INPUT_SIZE = 100 * 1024
MAX_CONTENT_INFLATION = 1.2


def _extract_url_from_text(text):
    """Find an http(s) URL embedded in short text (e.g. iOS Shortcut payloads)."""
    match = re.search(r'https?://\S+', text)
    return match.group(0).rstrip('.,;:!?)') if match else None


def validate_input(input_text):
    """Validate input and resolve to (content, url).

    For a URL: returns (Readability article dict, url).
    For text:  returns (string, None).
    For short text containing an embedded URL (under 500 chars): treats as
    URL submission, since iOS Shortcuts often send the page title plus link.
    """
    if not input_text or not input_text.strip():
        raise ValueError('Input text is empty')

    input_text = input_text.strip()

    if sys.getsizeof(input_text) > MAX_INPUT_SIZE:
        raise ValueError(f'Input text exceeds {MAX_INPUT_SIZE/1024:.1f} KB')

    if is_url(input_text):
        if len(input_text) > MAX_URL_LENGTH:
            raise ValueError(f'URL exceeds {MAX_URL_LENGTH} characters')

        html = fetch_url_content(input_text)
        article = extract_with_readability(html, url=input_text)
        if not article:
            raise ValueError('Unable to extract sufficient content from URL.')

        return article, input_text

    # Not a bare URL — check for embedded URL in short text.
    if len(input_text) < 500:
        embedded = _extract_url_from_text(input_text)
        if embedded and is_url(embedded):
            try:
                html = fetch_url_content(embedded)
                article = extract_with_readability(html, url=embedded)
                if article:
                    return article, embedded
            except Exception as e:
                logger.warning(f'Embedded URL fetch failed, using raw text: {e}')

    return input_text, None


# ---------- LLM-driven helpers ----------

def generate_title(text):
    """Generate a title from the first 300 chars of content."""
    system_prompt = (
        "Identify the title within this article content if one exists; "
        "otherwise generate a concise title that represents its essence. "
        "Output the title only, no prefix."
    )
    user_content = f"Article Content: {text[:300]}"

    try:
        if CONTENT_PROVIDER == 'ollama':
            title = generate_with_ollama(system_prompt, user_content,
                                         temperature=0.3, max_tokens=30)
            return title.split('\n')[0].strip().strip('"')
        elif CONTENT_PROVIDER == 'gemini' and GOOGLE_API_KEY:
            title = generate_with_gemini(system_prompt, user_content,
                                         temperature=0.3, max_tokens=20)
            return title.split('\n')[0].strip()
        else:
            response = openai_client.chat.completions.create(
                model=CONTENT_MODEL_OPENAI,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_content},
                ],
                temperature=0.3,
                max_tokens=20,
                stop=["\n"],
            )
            return response.choices[0].message.content.strip()
    except Exception as e:
        logger.error(f"generate_title: {e}")
        return "Untitled Episode"


def generate_summary(text):
    """Generate a 2-3 sentence summary from the first 1000 chars."""
    system_prompt = (
        "Generate a brief, engaging summary in 2-3 sentences. "
        "Focus on main points. Concise but informative."
    )
    user_content = f"Content: {text[:1000]}"

    try:
        if CONTENT_PROVIDER == 'ollama':
            return generate_with_ollama(system_prompt, user_content,
                                        temperature=0.7, max_tokens=150)
        elif CONTENT_PROVIDER == 'gemini' and GOOGLE_API_KEY:
            return generate_with_gemini(system_prompt, user_content,
                                        temperature=0.7, max_tokens=100)
        else:
            response = openai_client.chat.completions.create(
                model=CONTENT_MODEL_OPENAI,
                messages=[
                    {"role": "system", "content": system_prompt},
                    {"role": "user", "content": user_content},
                ],
                temperature=0.7,
                max_tokens=100,
            )
            return response.choices[0].message.content.strip()
    except Exception as e:
        logger.error(f"generate_summary: {e}")
        return "No summary available"


def save_episode_to_db(filename, title, description, duration=None):
    pub_date = datetime.now(timezone.utc).strftime('%a, %d %b %Y %H:%M:%S GMT')
    return db.add_episode(filename, title, description, pub_date, duration=duration)


def resolve_voice(original_url=None, requested_voice=None):
    """Per-request voice override falls back to TTS_VOICE env."""
    from config.config import TTS_VOICE
    return requested_voice or TTS_VOICE


def process_validated_input(content, original_url=None, voice=None):
    """Assemble the input package the TTS step needs.

    content is either a Readability article dict (URL path) or a string (text path).
    Returns dict with text, title, description, voice.
    """
    if original_url and isinstance(content, dict):
        cleaned_text = content.get('textContent', '').strip()

        title = content.get('title', '').strip() or generate_title(cleaned_text)
        byline = (content.get('byline') or '').strip()

        # Prepend title (and byline) so the TTS announces them.
        header = [title]
        if byline:
            header.append(f'By {byline}')
        cleaned_text = '\n\n'.join(header) + '\n\n' + cleaned_text
    else:
        cleaned_text = content
        title = generate_title(cleaned_text)
        byline = None

    summary = generate_summary(cleaned_text)
    resolved_voice = resolve_voice(original_url, voice)

    if original_url:
        parts = [f"From URL: {original_url}"]
        if byline:
            parts.append(f"By {byline}")
        parts.append(f"\n{summary}")
        description = '\n'.join(parts)
    else:
        description = summary

    return {
        'text': cleaned_text,
        'title': title,
        'description': description,
        'voice': resolved_voice,
    }
