"""RSS feed generation.

Generated from the SQLite episodes table on every /feed request. Standard
RSS 2.0 with the iTunes namespace for podcast-app metadata (image, duration).
"""
import xml.etree.ElementTree as ET
from xml.dom import minidom
from config.config import (
    FEED_TITLE,
    FEED_DESCRIPTION,
    BASE_URL,
    FEED_LANGUAGE,
    FEED_IMAGE,
)
from .database_service import db


def generate_feed():
    """Build the RSS XML and return it as a pretty-printed string."""
    rss = ET.Element(
        "rss",
        version="2.0",
        attrib={"xmlns:itunes": "http://www.itunes.com/dtds/podcast-1.0.dtd"},
    )
    channel = ET.SubElement(rss, "channel")

    ET.SubElement(channel, "title").text = FEED_TITLE
    ET.SubElement(channel, "description").text = FEED_DESCRIPTION
    ET.SubElement(channel, "link").text = f"{BASE_URL}/feed"
    ET.SubElement(channel, "language").text = FEED_LANGUAGE
    ET.SubElement(channel, "itunes:image", href=f"{BASE_URL}/static/images/{FEED_IMAGE}")

    for filename, title, description, pub_date, duration in db.get_all_episodes():
        item = ET.SubElement(channel, "item")
        ET.SubElement(item, "title").text = title
        ET.SubElement(item, "description").text = description
        ET.SubElement(
            item,
            "enclosure",
            url=f"{BASE_URL}/static/audio/{filename}",
            type="audio/mpeg",
        )
        ET.SubElement(item, "pubDate").text = pub_date
        ET.SubElement(item, "itunes:duration").text = duration or "00:00:00"

    rough = ET.tostring(rss, 'utf-8', method='xml')
    return minidom.parseString(rough).toprettyxml(indent="  ")
