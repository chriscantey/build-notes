"""TTS pipeline.

create_episode() is the entry point called by the background processor:

  1. Strip markdown so the TTS reads naturally and pauses at section breaks.
  2. Split into ~500-word segments on paragraph boundaries.
  3. Send each segment to the OpenAI-compatible TTS endpoint (Chatterbox in
     the running setup; OpenAI's hosted TTS would also work).
  4. Concatenate segments with the intro sound prepended via pydub.
  5. Export a single MP3 at 192k.
  6. Save metadata to SQLite.

Long articles can take 30-45 minutes — the OpenAI client timeout is bumped
to 60 minutes via httpx.Timeout to accommodate.
"""
from pydub import AudioSegment
from pathlib import Path
from datetime import datetime
import uuid
import re
import logging
import time
from dotenv import load_dotenv
from config.config import (
    TTS_MODEL,
    TTS_VOICE,
    TTS_SPEED,
    AUDIO_OUTPUT_FORMAT,
    AUDIO_OUTPUT_QUALITY,
    AUDIO_PATH,
    INTRO_SOUND_PATH,
)
from mutagen.mp3 import MP3
from .content_service import save_episode_to_db

logger = logging.getLogger(__name__)
load_dotenv()

from openai import OpenAI
import httpx
# Long articles take much longer than the 10-minute default.
client = OpenAI(timeout=httpx.Timeout(3600.0, connect=30.0))


def strip_markdown_for_tts(text):
    """Strip markdown syntax while preserving sentence structure for natural pauses.

    The TTS server creates ~350 ms silence at sentence boundaries. By making
    sure headings and list items end in terminal punctuation and are followed
    by blank lines, we get audio that pauses at section breaks instead of
    running everything together.
    """
    def _heading_pause(m):
        title = m.group(1).rstrip()
        if title and title[-1] not in '.!?:':
            title += '.'
        return title + '\n'

    text = re.sub(r'^#{1,6}\s+(.+)$', _heading_pause, text, flags=re.MULTILINE)

    def _list_item_pause(m):
        item = m.group(1).rstrip()
        if item and item[-1] not in '.!?:;':
            item += '.'
        return item + '\n'

    text = re.sub(r'^[\-\*\+]\s+(.+)$', _list_item_pause, text, flags=re.MULTILINE)
    text = re.sub(r'^\d+[\.\)]\s+(.+)$', _list_item_pause, text, flags=re.MULTILINE)
    text = re.sub(r'^[\-\*_]{3,}\s*$', '\n', text, flags=re.MULTILINE)

    # Strip remaining inline syntax.
    text = re.sub(r'\*\*(.+?)\*\*', r'\1', text)
    text = re.sub(r'__(.+?)__', r'\1', text)
    text = re.sub(r'\*(.+?)\*', r'\1', text)
    text = re.sub(r'(?<!\w)_(.+?)_(?!\w)', r'\1', text)
    text = re.sub(r'`(.+?)`', r'\1', text)
    text = re.sub(r'\[([^\]]+)\]\([^)]+\)', r'\1', text)
    text = re.sub(r'!\[([^\]]*)\]\([^)]+\)', r'\1', text)
    text = re.sub(r'^>\s?', '', text, flags=re.MULTILINE)
    text = re.sub(r'~~(.+?)~~', r'\1', text)
    text = re.sub(r'\n{3,}', '\n\n', text)
    return text.strip()


def split_text_for_tts(text, target_words=500):
    """Split into ~500-word segments on paragraph boundaries.

    Smaller segments give per-segment progress logging, recoverability if a
    segment fails, and shorter per-call timeouts. Falls back to sentence
    splitting if there are no paragraph boundaries.
    """
    paragraphs = re.split(r'\n+', text)
    segments, current, words = [], [], 0

    for para in paragraphs:
        para = para.strip()
        if not para:
            continue
        n = len(para.split())
        if words + n > target_words and current:
            segments.append('\n\n'.join(current))
            current, words = [para], n
        else:
            current.append(para)
            words += n

    if current:
        segments.append('\n\n'.join(current))

    if len(segments) <= 1 and len(text.split()) > target_words:
        sentences = re.split(r'(?<=[.!?])\s+', text)
        segments, current, words = [], [], 0
        for sent in sentences:
            n = len(sent.split())
            if words + n > target_words and current:
                segments.append(' '.join(current))
                current, words = [sent], n
            else:
                current.append(sent)
                words += n
        if current:
            segments.append(' '.join(current))

    return segments


def _segment_filename(base_filename, extension, is_final=False):
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in base_filename)
    stamp = datetime.now().strftime('%Y%m%d_%H%M%S')
    rand = uuid.uuid4().hex[:6]
    if is_final:
        return Path(AUDIO_PATH) / f"{safe}_{stamp}_{rand}.{extension}"
    return Path(AUDIO_PATH) / 'tmp' / f"{safe}_{stamp}_{rand}_segment.{extension}"


def _audio_duration_string(filepath):
    try:
        audio = MP3(filepath)
        seconds = int(audio.info.length)
        h, rem = divmod(seconds, 3600)
        m, s = divmod(rem, 60)
        return f"{h:02}:{m:02}:{s:02}"
    except Exception as e:
        logger.error(f'Duration read failed for {filepath}: {e}')
        return "00:00:00"


def create_episode(text, title, description, base_filename='episode', voice=None):
    """End-to-end TTS for one episode."""
    text = strip_markdown_for_tts(text)
    effective_voice = voice or TTS_VOICE
    total_words = len(text.split())

    segments = split_text_for_tts(text)
    logger.info(f'TTS: {len(text)} chars ({total_words} words), '
                f'{len(segments)} segments, voice: {effective_voice}')

    tmp_dir = Path(AUDIO_PATH) / 'tmp'
    tmp_dir.mkdir(parents=True, exist_ok=True)

    segment_paths = []
    t0 = time.time()

    for i, segment in enumerate(segments):
        seg_words = len(segment.split())
        seg_start = time.time()

        response = client.audio.speech.create(
            model=TTS_MODEL,
            voice=effective_voice,
            input=segment,
            response_format=AUDIO_OUTPUT_FORMAT,
            speed=TTS_SPEED,
        )

        seg_path = _segment_filename(base_filename, AUDIO_OUTPUT_FORMAT, is_final=False)
        response.stream_to_file(str(seg_path))

        if not seg_path.exists():
            logger.error(f'TTS segment {i+1}/{len(segments)} failed')
            continue

        elapsed = time.time() - t0
        logger.info(f'TTS [{i+1}/{len(segments)}] {seg_words} words, '
                    f'{time.time() - seg_start:.1f}s (elapsed: {elapsed:.0f}s)')
        segment_paths.append(seg_path)

    if not segment_paths:
        logger.error('No TTS segments produced')
        return None

    logger.info(f'TTS complete: {len(segment_paths)} segments in {time.time() - t0:.1f}s')

    # Assemble: intro + segments.
    combined = AudioSegment.empty()

    if INTRO_SOUND_PATH.exists():
        try:
            intro = AudioSegment.from_file(str(INTRO_SOUND_PATH))
            combined += intro
            logger.info(f'Added intro sound ({intro.duration_seconds:.2f}s)')
        except Exception as e:
            logger.error(f'Intro sound load failed: {e}')

    for seg_path in segment_paths:
        seg_audio = AudioSegment.from_file(str(seg_path), format=AUDIO_OUTPUT_FORMAT)
        combined += seg_audio

    final_path = _segment_filename(base_filename, AUDIO_OUTPUT_FORMAT, is_final=True)
    combined.export(str(final_path), format=AUDIO_OUTPUT_FORMAT,
                    bitrate=AUDIO_OUTPUT_QUALITY)
    logger.info(f'Exported episode: {final_path.name}')

    for seg_path in segment_paths:
        seg_path.unlink(missing_ok=True)

    duration = _audio_duration_string(final_path)
    if save_episode_to_db(final_path.name, title, description, duration=duration):
        logger.info(f'Episode saved: {title}')
        return final_path

    return None
