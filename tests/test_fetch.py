#!/usr/bin/env python3
#
# rdfeed-fetch: NTLM against the test vectors of MS-NLMP, the feed, the .rdp
# files, the icons, and whole subscriptions against tests/fake_rdweb.py.
#
# Copyright (C) 2026 Felitendo
# SPDX-License-Identifier: GPL-3.0-or-later

import hmac
import os
import struct
import subprocess
import sys
import tempfile
import unittest
import zlib

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)
import fake_rdweb  # noqa: E402

fetch = fake_rdweb.fetch
FETCH = os.path.join(HERE, "..", "src", "fetch", "rdfeed-fetch")


def png_info(png):
    """Width, height and the RGBA bytes of a PNG written by png_encode."""
    assert png[:8] == fetch.PNG_SIGNATURE
    width, height = struct.unpack(">II", png[16:24])
    pos, idat = 8, b""
    while pos < len(png):
        length = struct.unpack(">I", png[pos:pos + 4])[0]
        kind = png[pos + 4:pos + 8]
        if kind == b"IDAT":
            idat += png[pos + 8:pos + 8 + length]
        pos += 12 + length
    raw = zlib.decompress(idat)
    return width, height, raw


class Ntlm(unittest.TestCase):
    def test_md4(self):
        self.assertEqual(fetch.md4(b"").hex(), "31d6cfe0d16ae931b73c59d7e0c089c0")
        self.assertEqual(fetch.md4(b"abc").hex(), "a448017aaf21d8525fc10ae87aa6729d")
        self.assertEqual(fetch.md4(b"1234567890" * 8).hex(), "e33b4ddc9c38f2199c3e7b164fcc0536")

    # MS-NLMP 4.2.4: User, Domain, Password, server challenge 0123456789abcdef,
    # client challenge aa..aa, time 0, target info Domain and Server.
    def test_ntlmv2_vectors(self):
        key = fetch.ntowfv2("User", "Domain", "Password")
        self.assertEqual(key.hex(), "0c868a403bfd7a93a3001ef22ef02e3f")
        server, client = bytes.fromhex("0123456789abcdef"), b"\xaa" * 8
        lm = hmac.new(key, server + client, "md5").digest() + client
        self.assertEqual(lm.hex(), "86c35097ac9cec102554764a57cccc19aaaaaaaaaaaaaaaa")
        info = (struct.pack("<HH", 2, 12) + "Domain".encode("utf-16-le")
                + struct.pack("<HH", 1, 12) + "Server".encode("utf-16-le") + b"\x00" * 4)
        nt = fetch.ntlmv2_response(key, server, client, b"\x00" * 8, info)
        self.assertEqual(nt[:16].hex(), "68cd0ab851e51c96aabc927bebef6a1c")

    def test_domain_from_server(self):
        challenge, server_challenge = fake_rdweb.ntlm_challenge()
        message, domain = fetch.ntlm_authenticate(challenge, "jdoe", None, fake_rdweb.PASSWORD)
        self.assertEqual(domain, "CONTOSO")
        self.assertTrue(fake_rdweb.ntlm_check(message, server_challenge))
        message, _ = fetch.ntlm_authenticate(challenge, "jdoe", None, "wrong")
        self.assertFalse(fake_rdweb.ntlm_check(message, server_challenge))


class Feed(unittest.TestCase):
    def test_parse(self):
        name, apps = fetch.parse_feed(fake_rdweb.feed_xml())
        self.assertEqual(name, "Contoso Apps")
        self.assertEqual([a["slug"] for a in apps], ["winword", "excel", "powerpnt", "desktop"])
        self.assertEqual([a["type"] for a in apps], ["RemoteApp"] * 3 + ["Desktop"])
        self.assertEqual(apps[0]["rdp"], "/RDWeb/Pages/rdp/cpub-winword-RemoteApps-CmsRdsh.rdp")
        self.assertEqual(apps[1]["types"], ["xlsx", "csv"])
        self.assertEqual(apps[0]["types"], [])

    def test_known_types(self):
        self.assertEqual(fetch.known_types("||winword", "Word", "winword-x")[:2], ["docx", "docm"])
        self.assertEqual(fetch.known_types("||powerpoint", "PowerPoint", ""), "pptx pptm ppt potx potm ppsx pps odp".split())
        self.assertEqual(fetch.known_types("||trueview", "DWG TrueView", "trueview-x"), ["dwg", "dxf"])
        self.assertEqual(fetch.known_types("||pdf24", "PDF24", ""), ["pdf"])
        self.assertEqual(fetch.known_types("||wordpad", "WordPad", "wordpad-x"), [])
        self.assertEqual(fetch.known_types("||pwchange", "Passwort ändern", "pwchange-x"), [])

    def test_not_a_feed(self):
        for data in (b"<html><body>login</body></html>", b"", b"<RDWAPage/>"):
            with self.assertRaises(fetch.FeedError):
                fetch.parse_feed(data)

    def test_slugs(self):
        taken = set()
        self.assertEqual(fetch.make_slug("Passwort ändern", taken), "passwort-andern")
        self.assertEqual(fetch.make_slug("Passwort ändern", taken), "passwort-andern-2")
        self.assertEqual(fetch.make_slug("计算器", taken), "app")
        self.assertEqual(fetch.make_slug("!!!", taken), "app-2")
        self.assertEqual(fetch.common_suffix(["a-X-Y", "bb-X-Y"]), "-X-Y")
        self.assertEqual(fetch.common_suffix(["word", "sword"]), "")
        self.assertEqual(fetch.common_suffix(["only-one"]), "")


class Rdp(unittest.TestCase):
    def test_sanitize(self):
        text = fetch.decode_rdp(fake_rdweb.rdp_file("winword-x", "Word", "RemoteApp"))
        out = fetch.sanitize_rdp(text)
        self.assertIn("promptcredentialonce:i:1\r\n", out)
        self.assertIn("prompt for credentials on client:i:0\r\n", out)
        for gone in ("drivestoredirect", "devicestoredirect", "camerastoredirect"):
            self.assertNotIn(gone, out)
        self.assertIn("remoteapplicationprogram:s:||winword\r\n", out)

    def test_encodings(self):
        line = "full address:s:host\r\n"
        for data in (line.encode("utf-16"), line.encode("utf-16-le"), line.encode("utf-8-sig"), line.encode()):
            self.assertEqual(fetch.decode_rdp(data), line)

    def test_append(self):
        self.assertEqual(fetch.rdp_set("a:s:b\r\n", "promptcredentialonce", "i", "1"),
                         "a:s:b\r\npromptcredentialonce:i:1\r\n")


class Icons(unittest.TestCase):
    def test_32bpp(self):
        width, height, raw = png_info(fetch.ico_to_png(fake_rdweb.ico_32bpp(48, (30, 110, 220, 128))))
        self.assertEqual((width, height), (48, 48))
        self.assertEqual(raw[1:5], bytes((30, 110, 220, 128)))

    def test_24bpp_with_mask(self):
        size = 16
        header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 24, 0, 0, 0, 0, 0, 0)
        stride = ((size * 24 + 31) // 32) * 4
        pixels = (bytes((0, 0, 255)) * size + b"\x00" * (stride - size * 3)) * size
        # The top row of the image (the last one in the file) is transparent.
        mask = b"\x00\x00\x00\x00" * (size - 1) + b"\xff\xff\x00\x00"
        dib = header + pixels + mask
        ico = (struct.pack("<HHH", 0, 1, 1)
               + struct.pack("<BBBBHHII", size, size, 0, 0, 1, 24, len(dib), 22) + dib)
        width, height, raw = png_info(fetch.ico_to_png(ico))
        self.assertEqual((width, height), (16, 16))
        self.assertEqual(raw[1:5], bytes((255, 0, 0, 0)))
        row = 1 + width * 4
        self.assertEqual(raw[row + 1:row + 5], bytes((255, 0, 0, 255)))

    def test_png_frame_and_biggest(self):
        small = fake_rdweb.ico_32bpp(16)
        png = fetch.png_encode(2, 1, [bytes((1, 2, 3, 4, 5, 6, 7, 8))])
        # Two entries: a 16 px bitmap and a 256 px PNG (width 0 means 256).
        dib = small[22:]
        ico = (struct.pack("<HHH", 0, 1, 2)
               + struct.pack("<BBBBHHII", 16, 16, 0, 0, 1, 32, len(dib), 38)
               + struct.pack("<BBBBHHII", 0, 0, 0, 0, 1, 32, len(png), 38 + len(dib)) + dib + png)
        self.assertEqual(fetch.ico_to_png(ico), png)

    def test_garbage(self):
        self.assertIsNone(fetch.ico_to_png(b"not an icon"))
        self.assertIsNone(fetch.ico_to_png(b"\x00\x00\x01\x00\x01\x00" + b"\x00" * 16))


class Subscribe(unittest.TestCase):
    """rdfeed-fetch against the fake server, as rdfeed runs it."""

    @classmethod
    def setUpClass(cls):
        cls.server = fake_rdweb.serve()
        cls.url = cls.server.base + "/RDWeb/Feed/webfeed.aspx"

    @classmethod
    def tearDownClass(cls):
        cls.server.shutdown()

    def run_fetch(self, password, url=None, user="jdoe", domain=None):
        out = tempfile.mkdtemp()
        args = [sys.executable, FETCH, "--url", url or self.url, "--user", user, "--out", out, "--timeout", "5"]
        if domain is not None:
            args += ["--domain", domain]
        proc = subprocess.run(args, input=password + "\n", capture_output=True, text=True, timeout=60)
        return proc, out

    def test_ok(self):
        proc, out = self.run_fetch(fake_rdweb.PASSWORD)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        lines = [line.split("\t") for line in proc.stdout.splitlines()]
        self.assertIn(["workspace", "Contoso Apps"], lines)
        self.assertIn(["domain", "CONTOSO"], lines)
        self.assertIn(["app", "powerpnt", "RemoteApp", "PowerPoint"], lines)
        self.assertIn(["app", "desktop", "Desktop", "Contoso Desktop"], lines)
        with open(os.path.join(out, "apps.tsv")) as f:
            rows = [line.split("\t") for line in f.read().splitlines()]
        self.assertEqual(len(rows), 4)
        types = {row[0]: row[3] for row in rows}
        self.assertTrue(types["winword"].startswith("docx docm doc "))
        self.assertEqual(types["excel"], "xlsx csv")
        self.assertEqual(types["desktop"], "")
        with open(os.path.join(out, "rdp", "winword.rdp")) as f:
            rdp = f.read()
        self.assertIn("promptcredentialonce:i:1", rdp)
        self.assertNotIn("drivestoredirect", rdp)
        with open(os.path.join(out, "icons", "excel.png"), "rb") as f:
            self.assertEqual(png_info(f.read())[:2], (48, 48))

    def test_domain_given(self):
        proc, _ = self.run_fetch(fake_rdweb.PASSWORD, domain="contoso")
        self.assertEqual(proc.returncode, 0, proc.stderr)

    def test_wrong_password(self):
        proc, _ = self.run_fetch("nope")
        self.assertEqual(proc.returncode, fetch.EXIT_AUTH)

    def test_no_feed(self):
        proc, _ = self.run_fetch(fake_rdweb.PASSWORD, url=self.server.base + "/somewhere/else")
        self.assertEqual(proc.returncode, fetch.EXIT_NOFEED)

    def test_unreachable(self):
        proc, _ = self.run_fetch(fake_rdweb.PASSWORD, url="http://127.0.0.1:9/RDWeb/Feed/webfeed.aspx")
        self.assertEqual(proc.returncode, fetch.EXIT_NETWORK)


if __name__ == "__main__":
    unittest.main()
