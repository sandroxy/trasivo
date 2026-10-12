"""Check the fixture's HTTP framing with a persistent, non-retrying client."""
import hashlib
import http.client
import json
import threading
import unittest
from http.server import ThreadingHTTPServer

from server import Handler


class FixtureConnectionTests(unittest.TestCase):
    def setUp(self):
        self.server = ThreadingHTTPServer(('127.0.0.1', 0), Handler)
        self.server.media = {}
        self.worker = threading.Thread(target=self.server.serve_forever, daemon=True)
        self.worker.start()
        self.client = http.client.HTTPConnection('127.0.0.1', self.server.server_port, timeout=3)

    def tearDown(self):
        self.client.close()
        self.server.shutdown()
        self.server.server_close()
        self.worker.join(timeout=3)

    def test_download_and_validated_upload_reuse_the_same_connection(self):
        self.client.request('GET', '/download')
        connection = self.client.sock
        response = self.client.getresponse()
        self.assertEqual(response.status, 200)
        self.assertFalse(response.will_close)
        self.assertEqual(response.read(), b'trasivo-fixture\n' * 1024)

        body = b'fixture upload'
        for path, accepted in [('/rejected', False), ('/upload', True)] * 3:
            self.client.request('POST', path, body=body)
            response = self.client.getresponse()
            self.assertEqual(response.status, 200)
            self.assertEqual(json.loads(response.read()), {
                'success': accepted, 'sha256': hashlib.sha256(body).hexdigest(),
            })
            self.assertIs(self.client.sock, connection)

    def test_http_failure_explicitly_closes_the_connection(self):
        self.client.request('GET', '/failure')
        response = self.client.getresponse()
        self.assertEqual(response.status, 503)
        self.assertEqual(response.getheader('Connection'), 'close')
        self.assertTrue(response.will_close)
        response.read()
        self.assertIsNone(self.client.sock)
        self.client.request('GET', '/download')
        response = self.client.getresponse()
        self.assertEqual(response.status, 200)
        self.assertEqual(response.read(), b'trasivo-fixture\n' * 1024)


if __name__ == '__main__':
    unittest.main()
