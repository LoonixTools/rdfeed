#!/usr/bin/env python3
#
# A fake RD Web Access server for the tests: the feed behind the NTLM login,
# the forms ticket it hands out, .rdp files and icons. It checks the NTLMv2
# answer for real, against one user and password.
#
#   python3 tests/fake_rdweb.py [port]     serve until Ctrl+C
#
# Copyright (C) 2026 Felitendo
# SPDX-License-Identifier: GPL-3.0-or-later

import base64
import hmac
import http.server
import os
import socketserver
import struct
import sys
import threading
import urllib.parse

import importlib.machinery  # noqa: E402
import importlib.util  # noqa: E402

# rdfeed-fetch has no .py ending, so it is loaded by path.
_loader = importlib.machinery.SourceFileLoader(
    "rdfeed_fetch", os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "src", "fetch", "rdfeed-fetch"))
_spec = importlib.util.spec_from_loader("rdfeed_fetch", _loader)
fetch = importlib.util.module_from_spec(_spec)
_loader.exec_module(fetch)

DOMAIN = "CONTOSO"
USER = "jdoe"
PASSWORD = "Correct horse 1"
TOKEN = "5EC2E7F00DBA11ADE0F7EED5ACC0FFEE"

APPS = [
    ("winword-RemoteApps-CmsRdsh", "Word", "RemoteApp"),
    ("excel-RemoteApps-CmsRdsh", "Excel", "RemoteApp"),
    ("powerpnt-RemoteApps-CmsRdsh", "PowerPoint", "RemoteApp"),
    ("desktop-RemoteApps-CmsRdsh", "Contoso Desktop", "Desktop"),
]


def extensions(alias):
    """Excel comes with its file types, as an administrator would enter them."""
    if not alias.startswith("excel"):
        return "<FileExtensions />"
    return ('<FileExtensions><FileExtension Name=".xlsx" PrimaryHandler="True" />'
            '<FileExtension Name=".CSV" PrimaryHandler="False" /></FileExtensions>')


def feed_xml():
    resources = ""
    for alias, title, kind in APPS:
        resources += f"""
      <Resource ID="{alias}" Alias="{alias}" Title="{title}" LastUpdated="2026-10-01T08:00:00Z" Type="{kind}" ShowByDefault="True">
        <Icons>
          <IconRaw FileType="Ico" FileURL="/RDWeb/Pages/rdp/{alias}.ico" />
          <Icon32 Dimensions="32x32" FileType="Png" FileURL="/RDWeb/Pages/rdp/{alias}.png" />
        </Icons>
        {extensions(alias)}
        <Folders><Folder Name="/" /></Folders>
        <HostingTerminalServers>
          <HostingTerminalServer>
            <ResourceFile FileExtension=".rdp" URL="/RDWeb/Pages/rdp/cpub-{alias}.rdp" />
            <TerminalServerRef Ref="RDSH01.contoso.test" />
          </HostingTerminalServer>
        </HostingTerminalServers>
      </Resource>"""
    return f"""<?xml version="1.0" encoding="utf-8"?>
<ResourceCollection PubDate="2026-10-01T08:00:00Z" SchemaVersion="2.1" xmlns="http://schemas.microsoft.com/ts/2007/05/tswf">
  <Publisher LastUpdated="2026-10-01T08:00:00Z" Name="Contoso Apps" ID="RDSH01.contoso.test" Description="">
    <Resources>{resources}
    </Resources>
  </Publisher>
</ResourceCollection>
""".encode()


def rdp_file(alias, title, kind):
    lines = [
        "full address:s:RDBROKER.contoso.test",
        "gatewayhostname:s:gateway.contoso.test",
        "gatewayusagemethod:i:1",
        "promptcredentialonce:i:0",
        "prompt for credentials on client:i:1",
        "drivestoredirect:s:*",
        "devicestoredirect:s:*",
        "camerastoredirect:s:*",
        "loadbalanceinfo:s:tsv://MS Terminal Services Plugin.1.RemoteApps",
    ]
    if kind == "RemoteApp":
        lines += ["remoteapplicationmode:i:1", f"remoteapplicationprogram:s:||{alias.split('-')[0]}",
                  f"remoteapplicationname:s:{title}"]
    return ("\r\n".join(lines) + "\r\n").encode("utf-16")


def ico_32bpp(size=48, rgba=(30, 110, 220, 255)):
    """An .ico with one 32-bit bitmap frame, the way Windows writes them."""
    r, g, b, a = rgba
    header = struct.pack("<IiiHHIIiiII", 40, size, size * 2, 1, 32, 0, 0, 0, 0, 0, 0)
    pixels = bytes((b, g, r, a)) * (size * size)
    mask = b"\x00" * (((size + 31) // 32) * 4 * size)
    dib = header + pixels + mask
    return (struct.pack("<HHH", 0, 1, 1)
            + struct.pack("<BBBBHHII", size, size, 0, 0, 1, 32, len(dib), 22) + dib)


def ntlm_challenge():
    def av(kind, value):
        data = value.encode("utf-16-le")
        return struct.pack("<HH", kind, len(data)) + data
    info = (av(2, DOMAIN) + av(1, "RDWEB01") + av(4, "contoso.test") + av(3, "rdweb01.contoso.test")
            + struct.pack("<HH", 7, 8) + struct.pack("<Q", 133000000000000000) + struct.pack("<HH", 0, 0))
    server_challenge = os.urandom(8)
    target = DOMAIN.encode("utf-16-le")
    head = 56
    message = (b"NTLMSSP\x00" + struct.pack("<I", 2) + struct.pack("<HHI", len(target), len(target), head)
               + struct.pack("<I", 0xE2898215) + server_challenge + b"\x00" * 8
               + struct.pack("<HHI", len(info), len(info), head + len(target)) + fetch.NTLM_VERSION
               + target + info)
    return message, server_challenge


def ntlm_check(message, server_challenge):
    """True if the AUTHENTICATE message proves the password."""
    def field(i):
        length, _, offset = struct.unpack("<HHI", message[12 + 8 * i:20 + 8 * i])
        return message[offset:offset + length]
    nt, domain, user = field(1), field(2).decode("utf-16-le"), field(3).decode("utf-16-le")
    if user.lower() != USER or domain.upper() != DOMAIN or len(nt) < 32:
        return False
    key = fetch.ntowfv2(user, domain, PASSWORD)
    proof = hmac.new(key, server_challenge + nt[16:], "md5").digest()
    return hmac.compare_digest(proof, nt[:16])


class Handler(http.server.BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.1"

    def log_message(self, *args):
        pass

    def reply(self, status, body=b"", headers=None):
        self.send_response(status)
        for k, v in (headers or {}).items():
            if isinstance(v, list):
                for one in v:
                    self.send_header(k, one)
            else:
                self.send_header(k, v)
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def signed_in(self):
        cookies = self.headers.get("Cookie", "")
        return f"TSWAFeedAuthCookie={TOKEN}" in cookies

    def do_GET(self):
        path = urllib.parse.urlsplit(self.path).path
        lower = path.lower()
        if lower == "/rdweb/feed/webfeed.aspx":
            if self.signed_in():
                return self.reply(200, feed_xml(), {"Content-Type": "application/x-msts-radc+xml; charset=utf-8"})
            return self.reply(302, b"", {"Location": "/RDWeb/FeedLogin/WebFeedLogin.aspx"})
        if lower == "/rdweb/feedlogin/webfeedlogin.aspx":
            auth = self.headers.get("Authorization", "")
            if auth.startswith("NTLM "):
                message = base64.b64decode(auth[5:])
                kind = struct.unpack("<I", message[8:12])[0]
                if kind == 1:
                    challenge, self.server_challenge = ntlm_challenge()
                    return self.reply(401, b"", {"WWW-Authenticate": "NTLM " + base64.b64encode(challenge).decode()})
                if kind == 3 and ntlm_check(message, getattr(self, "server_challenge", b"")):
                    return self.reply(200, TOKEN.encode(), {"Content-Type": "application/x-msts-webfeed-login; charset=utf-8"})
            return self.reply(401, b"denied", {"WWW-Authenticate": ["NTLM", "Negotiate"], "Content-Type": "text/html"})
        if lower.startswith("/rdweb/pages/rdp/"):
            if not self.signed_in():
                return self.reply(302, b"", {"Location": "/RDWeb/Pages/en-US/login.aspx?ReturnUrl=" + path})
            name = path.rsplit("/", 1)[1]
            for alias, title, kind in APPS:
                if name == f"cpub-{alias}.rdp":
                    return self.reply(200, rdp_file(alias, title, kind), {"Content-Type": "application/x-rdp"})
                if name == f"{alias}.ico":
                    return self.reply(200, ico_32bpp(), {"Content-Type": "image/x-icon"})
                if name == f"{alias}.png":
                    return self.reply(404)
        return self.reply(404, b"<html>not here</html>", {"Content-Type": "text/html"})


class Server(socketserver.ThreadingMixIn, http.server.HTTPServer):
    daemon_threads = True
    allow_reuse_address = True


def serve(port=0):
    """Starts the server in a thread. Returns it; its URL base is server.base."""
    server = Server(("127.0.0.1", port), Handler)
    server.base = f"http://127.0.0.1:{server.server_address[1]}"
    threading.Thread(target=server.serve_forever, daemon=True).start()
    return server


if __name__ == "__main__":
    srv = serve(int(sys.argv[1]) if len(sys.argv) > 1 else 0)
    print(srv.base + "/RDWeb/Feed/webfeed.aspx", flush=True)
    try:
        threading.Event().wait()
    except KeyboardInterrupt:
        pass
