import hashlib
import json
import shutil
import ssl
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from urllib.parse import parse_qs, unquote, urlsplit


PACKAGE_ID = "RomanCuisset.OctetLedger"
SOURCE_ID = "OctetLedgerPrepublication"
PACKAGE = {"PackageIdentifier": PACKAGE_ID, "PackageName": "OctetLedger", "Publisher": "Roman Cuisset"}
LEGACY = {
    "x64": "F549C7A74C6294A672B8D2157212714ECF9F4A2B527D87FA7E2EAA5F3B0FF273",
    "arm64": "35ACC604730B55CD7CF96BB6676F8D9458F69668957E9553937C9D11169CA03B",
}


arch, candidate_file, certificate, key, address_file = sys.argv[1:]
candidate_file = Path(candidate_file)
candidate_path = f"/{candidate_file.name}"
with candidate_file.open("rb") as archive:
    candidate_hash = hashlib.file_digest(archive, "sha256").hexdigest()


def manifest(version, url, checksum):
    return {
        "PackageVersion": version,
        "DefaultLocale": {
            "PackageLocale": "en-US",
            "PackageName": PACKAGE["PackageName"],
            "Publisher": PACKAGE["Publisher"],
            "License": "MIT",
            "ShortDescription": "Lightweight Windows network traffic statistics.",
        },
        "Installers": [{
            "Architecture": arch,
            "InstallerType": "zip",
            "NestedInstallerType": "portable",
            "InstallerUrl": url,
            "InstallerSha256": checksum,
            "UpgradeBehavior": "install",
            "Commands": ["octetledger"],
            "NestedInstallerFiles": [{"RelativeFilePath": "octetledger.exe", "PortableCommandAlias": "octetledger"}],
        }],
    }


class SourceHandler(BaseHTTPRequestHandler):
    def json_response(self, data):
        body = json.dumps({"Data": data}).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.end_headers()
        self.wfile.write(body)

    def do_POST(self):
        if urlsplit(self.path).path != "/manifestSearch":
            self.send_error(404)
            return
        self.rfile.read(int(self.headers.get("Content-Length", "0")))
        items = [{"PackageVersion": version, "ProductCodes": [f"{PACKAGE_ID}_{SOURCE_ID}"]} for version in versions]
        self.json_response([{**PACKAGE, "Versions": items}])

    def send_candidate(self, send_body):
        self.send_response(200)
        self.send_header("Content-Type", "application/zip")
        self.send_header("Content-Length", str(candidate_file.stat().st_size))
        self.end_headers()
        if send_body:
            with candidate_file.open("rb") as archive:
                shutil.copyfileobj(archive, self.wfile)

    def do_HEAD(self):
        if urlsplit(self.path).path == candidate_path:
            self.send_candidate(False)
        else:
            self.send_error(404)

    def do_GET(self):
        uri = urlsplit(self.path)
        if uri.path == "/information":
            self.json_response({"SourceIdentifier": SOURCE_ID, "ServerSupportedVersions": ["1.4.0"]})
        elif unquote(uri.path).casefold() == f"/packageManifests/{PACKAGE_ID}".casefold():
            query = {key.casefold(): values for key, values in parse_qs(uri.query).items()}
            version = (query.get("version") or query.get("packageversion") or [None])[0]
            result = [item for name, item in versions.items() if version is None or version == name]
            self.json_response({"PackageIdentifier": PACKAGE_ID, "Versions": result})
        elif uri.path == candidate_path:
            self.send_candidate(True)
        else:
            self.send_error(404)


with ThreadingHTTPServer(("127.0.0.1", 0), SourceHandler) as server:
    tls = ssl.SSLContext(ssl.PROTOCOL_TLS_SERVER)
    tls.load_cert_chain(certificate, key)
    server.socket = tls.wrap_socket(server.socket, server_side=True)
    base = f"https://127.0.0.1:{server.server_port}"
    upstream = "https://github.com/Roman-Cuisset/octet-ledger/releases/download/v0.3.0"
    versions = {
        "0.11.1": manifest("0.11.1", f"{base}{candidate_path}", candidate_hash),
        "0.3.0": manifest("0.3.0", f"{upstream}/OctetLedger-0.3.0-win-{arch}.zip", LEGACY[arch]),
    }
    Path(address_file).write_text(base, encoding="ascii")
    server.serve_forever()
