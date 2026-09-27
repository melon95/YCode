import base64
import copy
from pathlib import Path
import sys
import tempfile
import unittest
import xml.etree.ElementTree as ET
sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from verify_appcast import validate, NAMESPACE
from check_release_version import check


class AppcastTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'YCode-0.7.0.zip'
        self.archive.write_bytes(b'test archive')
        self.feed = self.root / 'appcast.xml'
        self.key = base64.b64encode(bytes(32)).decode()
        self.info = {'CFBundleIdentifier': 'dev.ycode.app', 'CFBundleVersion': '100001',
                     'CFBundleShortVersionString': '0.7.0', 'LSMinimumSystemVersion': '14.0',
                     'SUFeedURL': 'https://github.com/melon95/YCode/releases/latest/download/appcast.xml',
                     'SUPublicEDKey': self.key}
        self.tree = ET.Element('rss')
        self.item = ET.SubElement(ET.SubElement(self.tree, 'channel'), 'item')
        for name, key in [('version', 'CFBundleVersion'), ('shortVersionString', 'CFBundleShortVersionString'), ('minimumSystemVersion', 'LSMinimumSystemVersion')]:
            ET.SubElement(self.item, NAMESPACE + name).text = self.info[key]
        self.enclosure = ET.SubElement(self.item, 'enclosure', {
            'url': 'https://github.com/melon95/YCode/releases/download/v0.7.0/YCode-0.7.0.zip',
            'length': str(self.archive.stat().st_size), NAMESPACE + 'edSignature': base64.b64encode(bytes(64)).decode()})

    def run_validation(self):
        ET.ElementTree(self.tree).write(self.feed)
        return validate(self.feed, self.archive, self.info, 'melon95/YCode', self.key)

    def test_valid_metadata(self):
        self.assertEqual(len(base64.b64decode(self.run_validation())), 64)

    def test_archive_length_mismatch(self):
        self.archive.write_bytes(b'tampered')
        with self.assertRaisesRegex(ValueError, 'length'): self.run_validation()

    def test_wrong_version_or_destination(self):
        for value in ['https://example.com/YCode-0.7.0.zip', 'https://github.com/melon95/YCode/releases/download/v0.6.0/YCode-0.7.0.zip']:
            self.enclosure.set('url', value)
            with self.assertRaisesRegex(ValueError, 'URL/name'): self.run_validation()

    def test_missing_signature(self):
        self.enclosure.attrib.pop(NAMESPACE + 'edSignature')
        with self.assertRaisesRegex(ValueError, 'signature'): self.run_validation()

    def test_wrong_key_or_development_bundle(self):
        original = copy.deepcopy(self.info)
        for field, value in [('SUPublicEDKey', 'wrong'), ('CFBundleIdentifier', 'dev.ycode.native.dev')]:
            self.info = {**original, field: value}
            with self.assertRaises(ValueError): self.run_validation()

    def test_wrong_build_and_multiple_items(self):
        self.item.find(NAMESPACE + 'version').text = '100000'
        with self.assertRaisesRegex(ValueError, 'version'): self.run_validation()
        self.item.find(NAMESPACE + 'version').text = '100001'
        self.tree.find('channel').append(copy.deepcopy(self.item))
        with self.assertRaisesRegex(ValueError, 'exactly one'): self.run_validation()


class ReleaseVersionTests(unittest.TestCase):
    def test_new_version_and_draft_retry(self):
        check('v0.7.0', [{'tag_name': 'v0.6.0', 'draft': False, 'prerelease': False}, {'tag_name': 'v0.7.0', 'draft': True, 'prerelease': False}])

    def test_reject_public_release_and_downgrade(self):
        published = [{'tag_name': 'v0.7.0', 'draft': False, 'prerelease': False}]
        for tag in ['v0.7.0', 'v0.6.0']:
            with self.assertRaises(ValueError): check(tag, published)

    def test_reject_unstable_or_unsafe_tag(self):
        for tag in ['v0.7.0-beta', '../v1.0.0', 'v01.0.0', 'main']:
            with self.assertRaises(ValueError): check(tag, [])


if __name__ == '__main__': unittest.main()
