"""Background episode processor.

A single process-wide threading.Lock serializes episode processing so Ollama
and Chatterbox TTS never compete for GPU memory. Concurrent POST requests
return 202 immediately and queue behind the lock.
"""
import threading
import logging
from .tts_service import create_episode
from .content_service import process_validated_input

logger = logging.getLogger(__name__)

# Process-wide lock. Pairs with `--workers 1` in the gunicorn command —
# multiple workers would each have their own lock and defeat serialization.
_gpu_lock = threading.Lock()


def process_episode_async(content, original_url=None, voice=None):
    """Run the episode pipeline in a daemon thread."""

    def _process():
        with _gpu_lock:
            try:
                processed = process_validated_input(content, original_url, voice=voice)

                output_path = create_episode(
                    text=processed['text'],
                    title=processed['title'],
                    description=processed['description'],
                    base_filename=processed['title'].lower().replace(' ', '-')[:50],
                    voice=processed['voice']
                )

                if output_path:
                    logger.info(f'Successfully processed episode: {processed["title"]}')
                else:
                    logger.error('Failed to create episode')
            except Exception as e:
                import traceback
                logger.error(f'Error in background processing: {str(e)}\n{traceback.format_exc()}')

    thread = threading.Thread(target=_process)
    thread.daemon = True
    thread.start()
