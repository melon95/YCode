#!/usr/bin/env python3
"""Validate the feed against the delivered app, archive and pinned public key."""
import argparse
import base64
import plistlib
import re
import subprocess
from pathlib import Path
import xml.etree.ElementTree as ET

NAMESPACE = '{http://www.andymatuschak.org/xml-namespaces/sparkle}'
REPOSITORY = re.compile(r'[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+')
VERSION = re.compile(r'(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)')


def validate(feed, archive, info, repository, public_key):
    if not REPOSITORY.fullmatch(repository):
        raise ValueError('Invalid GitHub repository')
    version = info['CFBundleShortVersionString']
    if not VERSION.fullmatch(version):
        raise ValueError('Version must be x.y.z')
    expected_feed = f'https://github.com/{repository}/releases/latest/download/appcast.xml'
    if info.get('SUFeedURL') != expected_feed or info.get('SUPublicEDKey') != public_key:
        raise ValueError('Bundle feed/public key differs from the release configuration')
    if info.get('CFBundleIdentifier') != 'dev.ycode.app':
        raise ValueError('Only the release bundle identifier can enter the update feed')
    if len(base64.b64decode(public_key, validate=True)) != 32:
        raise ValueError('Invalid public key')
    items = ET.parse(feed).findall('./channel/item')
    if len(items) != 1:
        raise ValueError('Expected exactly one full update')
    item = items[0]
    for name, key in [('version', 'CFBundleVersion'), ('shortVersionString', 'CFBundleShortVersionString'), ('minimumSystemVersion', 'LSMinimumSystemVersion')]:
        if item.findtext(NAMESPACE + name) != info[key]:
            raise ValueError(f'Incorrect {name}')
    enclosures = item.findall('enclosure')
    if len(enclosures) != 1 or item.find(NAMESPACE + 'deltas') is not None:
        raise ValueError('Expected a single full archive without deltas')
    enclosure = enclosures[0]
    expected_name = f'YCode-{version}.zip'
    expected_url = f'https://github.com/{repository}/releases/download/v{version}/{expected_name}'
    if archive.name != expected_name or enclosure.get('url') != expected_url:
        raise ValueError('Archive URL/name must point to this exact versioned release')
    if enclosure.get('length') != str(archive.stat().st_size):
        raise ValueError('Incorrect archive length')
    signature = enclosure.get(NAMESPACE + 'edSignature', '')
    if len(base64.b64decode(signature, validate=True)) != 64:
        raise ValueError('Missing or invalid EdDSA signature')
    return signature


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    for name in ['feed', 'archive', 'app', 'repository', 'public-key-file']:
        parser.add_argument('--' + name, required=True)
    args = parser.parse_args()
    archive = Path(args.archive)
    info = plistlib.loads((Path(args.app) / 'Contents/Info.plist').read_bytes())
    public_key = Path(args.public_key_file).read_text().strip()
    signature = validate(Path(args.feed), archive, info, args.repository, public_key)
    subprocess.run(['swift', str(Path(__file__).with_name('verify_update_signature.swift')), public_key, str(archive), signature], check=True)
    print('Appcast metadata and archive EdDSA signature verified.')


if __name__ == '__main__':
    main()
