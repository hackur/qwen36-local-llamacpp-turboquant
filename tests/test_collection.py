import importlib.util
import hashlib
import json
from pathlib import Path
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('collection', Path(__file__).resolve().parents[1] / 'scripts/collect-source.py')
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)


class CollectionTests(unittest.TestCase):
    def test_complete_archive_and_explicit_bounded_handoff(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / 'page.html'
            raw = b'<style>noise</style><script>noise()</script><p>Fact &amp; evidence</p><table><tr><td>42</td></tr></table>' + b'<p>More facts</p>' * 3000
            source.write_bytes(raw)
            out = Path(d) / 'bundle'
            m = mod.collect(source, out, url='https://example.test/a', max_chars=30)
            self.assertEqual((out / 'source.bin').read_bytes(), raw)
            self.assertEqual(m['sha256'], hashlib.sha256(raw).hexdigest())
            clean = (out / 'readable.txt').read_text()
            self.assertNotIn('noise', clean)
            self.assertIn('Fact & evidence', clean)
            self.assertIn('42', clean)
            self.assertGreater(len(clean), 8000)
            self.assertTrue(m['handoff_truncated'])
            self.assertFalse(m['source_truncated'])
            self.assertIn('truncated: True', (out / 'handoff.md').read_text())
            with self.assertRaises(FileExistsError):
                mod.collect(source, out, url='https://example.test/a')

    def test_gateway_envelope_retains_links_structured_data_and_capture_limits(self):
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / 'capture.json'
            source.write_text(json.dumps({'result': {'url': 'https://example.test/final', 'title': 'Evidence', 'capturedAt': '2026-11-04T00:00:00Z', 'html': '<a href="/next">Next</a><script type="application/ld+json">{"price":42}</script>'}}))
            out = Path(d) / 'bundle'
            m = mod.collect(source, out, url='https://example.test', fmt='json', source_truncated=True)
            self.assertEqual(m['captured_url'], 'https://example.test/final')
            self.assertEqual(m['captured_at'], '2026-11-04T00:00:00Z')
            self.assertIn('archived_at', m)
            self.assertTrue(m['source_truncated'])
            self.assertFalse(m['handoff_truncated'])
            self.assertIn('"price":42', (out / 'readable.txt').read_text())
            self.assertIn('/next', (out / 'readable.txt').read_text())

    def test_plain_text_preserves_spacing_and_failed_json_does_not_create_bundle(self):
        self.assertEqual(mod.readable(b'  code\n    indent\n', 'text'), '  code\n    indent\n')
        with tempfile.TemporaryDirectory() as d:
            source = Path(d) / 'bad.json'; source.write_text('{')
            out = Path(d) / 'bundle'
            with self.assertRaises(json.JSONDecodeError):
                mod.collect(source, out, url='x', fmt='json')
            self.assertFalse(out.exists())
