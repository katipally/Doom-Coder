#!/usr/bin/env python3
"""
update_appcast.py — Prepend a new release entry to appcast.xml.

Usage:
    python3 scripts/update_appcast.py \
        --version 0.2.0 \
        --build 2 \
        --signature <sparkle-edsignature> \
        --size <bytes> \
        --download-url https://github.com/katipally/DoomCoder/releases/download/v0.2.0/DoomCoder-0.2.0.zip
"""
import argparse
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from pathlib import Path

SPARKLE_NS = "http://www.andymatuschak.org/xml-namespaces/sparkle"
DC_NS = "http://purl.org/dc/elements/1.1/"

ET.register_namespace("sparkle", SPARKLE_NS)
ET.register_namespace("dc", DC_NS)


def s(tag: str) -> str:
    return f"{{{SPARKLE_NS}}}{tag}"


def update_appcast(version: str, build: str, signature: str, size: int, download_url: str) -> None:
    appcast_path = Path(__file__).parent.parent / "appcast.xml"
    tree = ET.parse(appcast_path)
    root = tree.getroot()
    channel = root.find("channel")
    assert channel is not None, "No <channel> element found in appcast.xml"

    item = ET.Element("item")

    title = ET.SubElement(item, "title")
    title.text = f"Version {version}"

    pub_date = ET.SubElement(item, "pubDate")
    pub_date.text = datetime.now(timezone.utc).strftime("%a, %d %b %Y %H:%M:%S +0000")

    release_notes = ET.SubElement(item, s("releaseNotesLink"))
    release_notes.text = f"https://github.com/katipally/DoomCoder/releases/tag/v{version}"

    min_sys = ET.SubElement(item, s("minimumSystemVersion"))
    min_sys.text = "14.0"

    enclosure = ET.SubElement(item, "enclosure")
    enclosure.set("url", download_url)
    enclosure.set(s("version"), build)
    enclosure.set(s("shortVersionString"), version)
    enclosure.set(s("edSignature"), signature)
    enclosure.set("length", str(size))
    enclosure.set("type", "application/octet-stream")

    # Insert new item before any existing items (newest first)
    children = list(channel)
    insert_pos = next(
        (i for i, c in enumerate(children) if c.tag == "item"),
        len(children)
    )
    channel.insert(insert_pos, item)

    ET.indent(tree, space="    ")
    tree.write(str(appcast_path), xml_declaration=True, encoding="UTF-8")
    print(f"✅ appcast.xml updated with version {version} (build {build})")


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description="Add a release entry to appcast.xml")
    parser.add_argument("--version", required=True, help="Marketing version e.g. 0.2.0")
    parser.add_argument("--build", required=True, help="Build number (integer string)")
    parser.add_argument("--signature", required=True, help="Sparkle EdDSA signature")
    parser.add_argument("--size", required=True, type=int, help="ZIP file size in bytes")
    parser.add_argument("--download-url", required=True, help="Direct download URL for the ZIP")
    args = parser.parse_args()
    update_appcast(args.version, args.build, args.signature, args.size, args.download_url)
