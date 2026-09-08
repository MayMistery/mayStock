"""Resolver protocol tests use synthetic wrappers and do not fetch the network."""
import base64
import json
import unittest
import urllib.parse

from Intelligence.google_news import GoogleNewsResolveError, resolve_google_url


OPAQUE = "https://news.google.com/rss/articles/QVVfeXFMT3BhcXVlVG9rZW4?oc=5"
PUBLISHER = "https://publisher.example/article?edition=us&topic=finance"


def legacy(url):
    value = url.encode()
    count, length = len(value), bytearray()
    while count >= 128:
        length.append((count & 127) | 128)
        count >>= 7
    length.append(count)
    token = base64.urlsafe_b64encode(b"\x08\x13\x22" + length + value + b"\xd2\x01\x00").decode().rstrip("=")
    return "https://news.google.com/articles/" + token


def rpc_response(url=PUBLISHER, rpc="Fbv4je", payload_kind="garturlres"):
    result = json.dumps([["wrb.fr", rpc, json.dumps([payload_kind, url]), None, None, None, "generic"],
                         ["di", 1], ["af.httprm", 1]])
    return ")]}'\n\n" + str(len(result)) + "\n" + result + "\n"


class GoogleNewsTests(unittest.TestCase):
    def test_legacy_short_and_multibyte_lengths_need_no_network(self):
        for original in [PUBLISHER, "https://publisher.example/" + "a" * 300]:
            self.assertEqual(resolve_google_url(legacy(original), lambda _: self.fail("network used")), original)

    def test_legacy_rejects_http_credentials_and_private_addresses(self):
        for original in ["http://publisher.example/a", "https://user:password@publisher.example/a",
                         "https://127.0.0.1/a", "https://[::1]/a", "https://news.google.com/articles/x"]:
            with self.subTest(original=original), self.assertRaises(GoogleNewsResolveError):
                resolve_google_url(legacy(original), lambda _: self.fail("network used"))

    def test_current_signed_protocol_and_escaped_publisher_url(self):
        calls = []

        def download(url, data=None):
            calls.append((url, data))
            if data is None:
                return url, '<c-wiz><div data-n-a-ts="1788839782" data-n-a-sg="abc&amp;def"></div></c-wiz>', "text/html"
            form = urllib.parse.parse_qs(data.decode())
            outer = json.loads(form["f.req"][0])
            self.assertEqual(outer[0][0][0], "Fbv4je")
            inner = json.loads(outer[0][0][1])
            self.assertEqual(inner[0], "garturlreq")
            self.assertEqual(inner[-2:], [1788839782, "abc&def"])
            return url, rpc_response(), "application/json"

        self.assertEqual(resolve_google_url(OPAQUE, download), PUBLISHER)
        self.assertEqual(len(calls), 2)
        self.assertEqual(urllib.parse.urlsplit(calls[1][0]).hostname, "news.google.com")

    def test_one_get_redirect_and_explicit_canonical(self):
        self.assertEqual(resolve_google_url(OPAQUE, lambda _: (PUBLISHER, "publisher body", "text/html")), PUBLISHER)
        self.assertEqual(resolve_google_url(OPAQUE, lambda url: (url,
            '<a href="https://unrelated.example/"></a><link rel="canonical" href="' + PUBLISHER + '">',
            "text/html")), PUBLISHER)

    def test_blocked_page_is_not_a_publisher_and_never_guesses_links(self):
        calls = []

        def download(url, data=None):
            calls.append(url)
            return url, '<a href="https://unrelated.example/">Privacy</a>Enable JavaScript', "text/html"

        with self.assertRaisesRegex(GoogleNewsResolveError, "GOOGLE_NEWS_PARAMETERS"):
            resolve_google_url(OPAQUE, download)
        self.assertEqual(len(calls), 1)

    def test_rpc_requires_correct_identifier_and_response_kind(self):
        for body in [rpc_response(rpc="wrong"), rpc_response(payload_kind="other"), ")]}'\n\n[]",
                     rpc_response(url="https://news.google.com/articles/another")]:
            def download(url, data=None):
                return (url, '<div data-n-a-ts="1" data-n-a-sg="signature"></div>' if data is None else body,
                        "text/html" if data is None else "application/json")
            with self.subTest(body=body), self.assertRaises(GoogleNewsResolveError):
                resolve_google_url(OPAQUE, download)

    def test_network_error_is_sanitized(self):
        def download(url, data=None):
            raise OSError("private diagnostic /local/path credential=secret")

        with self.assertRaises(GoogleNewsResolveError) as failure:
            resolve_google_url(OPAQUE, download)
        self.assertNotIn("secret", str(failure.exception))
        self.assertNotIn("local", str(failure.exception))

    def test_non_google_passthrough_and_rejected_wrapper_shapes(self):
        self.assertEqual(resolve_google_url(PUBLISHER, lambda _: self.fail("network used")), PUBLISHER)
        for url in ["https://news.google.com/rss/search?q=bitcoin", "http://news.google.com/articles/abcdefgh",
                    "https://news.google.com:8443/articles/abcdefgh", "https://news.google.com/articles/../invalid"]:
            with self.subTest(url=url), self.assertRaises(GoogleNewsResolveError):
                resolve_google_url(url, lambda _: self.fail("network used"))


if __name__ == "__main__":
    unittest.main()
