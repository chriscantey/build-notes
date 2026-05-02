"""POST /create endpoint.

Accepts a URL or raw text, validates it synchronously so the client gets a
meaningful 400 on bad input, then hands processing off to a background thread
and returns 202 Accepted immediately.
"""
from flask import Blueprint, request, jsonify, render_template
from ..services.background_tasks import process_episode_async
from ..services.content_service import validate_input
from ..middleware.auth import require_api_key
import logging

logger = logging.getLogger(__name__)

create = Blueprint('create', __name__)


@create.route('', methods=['GET'])
def create_form():
    """Browser form for submitting URLs or pasted text."""
    return render_template('create.html')


@create.route('', methods=['POST'])
@require_api_key
def create_episode_endpoint():
    """Create an episode from input (text or URL).

    Body (JSON):
      input: URL string or raw text content (required)
      url:   explicit URL to fetch from (optional, takes priority over input)
      voice: TTS voice override for this episode (optional)
    """
    data = request.get_json()

    if not data or 'input' not in data:
        return jsonify({'error': 'Missing input parameter'}), 400

    try:
        explicit_url = data.get('url', '').strip()
        input_value = data['input']

        if explicit_url:
            logger.info(f'Explicit url parameter provided: {explicit_url}')
            content, original_url = validate_input(explicit_url)
        else:
            content, original_url = validate_input(input_value)

        voice = data.get('voice')

        # Hand off to a daemon thread. The thread acquires the GPU lock
        # before doing any LLM or TTS work.
        process_episode_async(content, original_url, voice=voice)

        return jsonify({
            'message': 'Request accepted for processing',
            'status': 'processing'
        }), 202

    except ValueError as e:
        logger.error(f'Input validation error: {str(e)}')
        return jsonify({'error': str(e)}), 400
    except Exception as e:
        logger.error(f'Error initiating processing: {str(e)}', exc_info=True)
        return jsonify({'error': str(e)}), 500
