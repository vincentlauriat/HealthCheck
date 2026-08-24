#!/usr/bin/env python3
"""Insère ou remplace l'item d'une version dans appcast.xml (flux Sparkle).

Appelé par Scripts/release.sh une fois le DMG notarisé ET stapleé : le staple
réécrit le DMG, donc toute signature calculée avant serait invalide chez
l'utilisateur final.
"""
import argparse
import os
import xml.etree.ElementTree as ET
from datetime import datetime, timezone
from email.utils import format_datetime

SPARKLE = "http://www.andymatuschak.org/xml-namespaces/sparkle"
ET.register_namespace("sparkle", SPARKLE)


def s(tag):
    return f"{{{SPARKLE}}}{tag}"


def load_or_create(path, title, feed_url):
    if os.path.exists(path):
        tree = ET.parse(path)
        channel = tree.getroot().find("channel")
        if channel is None:
            raise SystemExit(f"{path} : pas d'élément <channel>")
        return tree, channel

    rss = ET.Element("rss", {"version": "2.0"})
    channel = ET.SubElement(rss, "channel")
    ET.SubElement(channel, "title").text = title
    ET.SubElement(channel, "link").text = feed_url
    ET.SubElement(channel, "description").text = f"Mises à jour de {title}"
    ET.SubElement(channel, "language").text = "fr"
    return ET.ElementTree(rss), channel


def main():
    p = argparse.ArgumentParser()
    p.add_argument("--appcast", required=True)
    p.add_argument("--title", required=True)
    p.add_argument("--feed-url", required=True)
    p.add_argument("--short-version", required=True, help="CFBundleShortVersionString")
    p.add_argument("--version", required=True, help="CFBundleVersion, ce que Sparkle compare")
    p.add_argument("--minimum-system-version", required=True)
    p.add_argument("--url", required=True)
    p.add_argument("--signature", required=True)
    p.add_argument("--length", required=True)
    args = p.parse_args()

    tree, channel = load_or_create(args.appcast, args.title, args.feed_url)

    # Rejouer une release (retry de notarisation) ne doit pas empiler deux
    # items pour la même build : on remplace.
    for item in channel.findall("item"):
        existing = item.find(s("version"))
        if existing is not None and existing.text == args.version:
            channel.remove(item)

    item = ET.Element("item")
    ET.SubElement(item, "title").text = args.short_version
    ET.SubElement(item, "pubDate").text = format_datetime(datetime.now(timezone.utc))
    ET.SubElement(item, s("version")).text = args.version
    ET.SubElement(item, s("shortVersionString")).text = args.short_version
    ET.SubElement(item, s("minimumSystemVersion")).text = args.minimum_system_version
    ET.SubElement(item, "enclosure", {
        "url": args.url,
        s("edSignature"): args.signature,
        "length": args.length,
        "type": "application/octet-stream",
    })

    # La plus récente en tête.
    channel.insert(len(list(channel)) - len(channel.findall("item")), item)

    ET.indent(tree, space="    ")
    tree.write(args.appcast, encoding="utf-8", xml_declaration=True)
    print(f"  appcast mis à jour : {args.appcast} (version {args.version})")


if __name__ == "__main__":
    main()
