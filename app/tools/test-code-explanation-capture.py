"""Regression für veraltete, fehlgeschlagene und unvollständige Sichtbelege."""
import importlib.util
from pathlib import Path
import tempfile
import threading
import time
import unittest

spec = importlib.util.spec_from_file_location('capture', Path(__file__).with_name('code-explanation-test.py'))
capture = importlib.util.module_from_spec(spec)
spec.loader.exec_module(capture)


class CaptureTests(unittest.TestCase):
    def test_stale_failure_and_partial_pair(self):
        with tempfile.TemporaryDirectory(prefix='fastra-capture-') as directory:
            base = Path(directory)
            visual = base / 'visual'; visual.mkdir()
            (base / 'host-captured').write_text('FAIL screenshot capture')
            (visual / 'explanation-ready.de.400.png').write_bytes(b'old')
            with self.assertRaisesRegex(AssertionError, 'confirmation missing'):
                capture.capture_images(base, visual, 'de', 'explanation-ready', .1)

    def test_matching_success_and_failure(self):
        for outcome in ['pair', 'missing900', 'failure']:
            with self.subTest(outcome=outcome), tempfile.TemporaryDirectory(prefix='fastra-capture-') as directory:
                base = Path(directory)
                visual = base / 'visual'; visual.mkdir()
                def answer():
                    while not (base / 'host-capture').exists(): time.sleep(.005)
                    token = (base / 'host-capture').read_text()
                    for width in ((400, 900) if outcome == 'pair' else (400,)):
                        (visual / f'{token}.de.{width}.png').write_bytes(b'\x89PNG\r\n\x1a\nfixture')
                    status = 'FAIL' if outcome == 'failure' else 'PASS'
                    (base / 'host-captured').write_text(f'{status} token={token} widths=400,900')
                thread = threading.Thread(target=answer); thread.start()
                try:
                    if outcome == 'pair':
                        self.assertEqual(len(capture.capture_images(base, visual, 'de', 'explanation-ready')), 2)
                    else:
                        with self.assertRaises(AssertionError):
                            capture.capture_images(base, visual, 'de', 'explanation-ready')
                finally: thread.join()


if __name__ == '__main__': unittest.main()
