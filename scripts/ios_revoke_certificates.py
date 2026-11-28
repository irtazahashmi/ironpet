#!/usr/bin/env python3
"""Revokes the signing certificates that one TestFlight upload made Xcode create through the App Store Connect API key.

On a GitHub runner the keychain has no signing identity, so the archive's automatic signing creates an Apple Development
certificate through the key. The runner and that certificate's private key are thrown away after the job, but the certificate
stays in the developer account, and once the account holds Apple's maximum the next upload fails. scripts/ios_testflight.sh calls
this around the build:

  ios_revoke_certificates.py snapshot FILE   write the SHA-1 of every code signing identity in the keychain to FILE
  ios_revoke_certificates.py revoke FILE     revoke, in the developer account, each certificate the key created ("Created
                                             via API") whose identity is not in FILE, matched by serial number

revoke reads the key from ASC_KEY_FILE, ASC_KEY_ID and ASC_ISSUER_ID. It needs only python3, openssl and macOS's security tool.
"""
import base64
import json
import os
import re
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request

API = "https://api.appstoreconnect.apple.com/v1"
SIGNING_NAMES = ("Apple Development:", "Apple Distribution:", "iPhone Developer:", "iPhone Distribution:")
# Apple names a certificate requested through an API key "Created via API", where one requested by a person carries their
# name. Only those are revoked, so a certificate a maintainer's own Xcode creates during a local build is left alone.
API_CREATED = "Created via API"


def run(args, data=None):
    result = subprocess.run(args, input=data, capture_output=True)
    if result.returncode != 0:
        raise RuntimeError(f"{args[0]} {args[1]} failed: {result.stderr.decode(errors='replace').strip()}")
    return result.stdout


def warn(message):
    prefix = "::warning::" if os.environ.get("GITHUB_ACTIONS") == "true" else "warning: "
    print(prefix + message, file=sys.stderr)


def identities():
    """SHA-1 to name of every code signing identity in the keychain search list, valid or not."""
    out = run(["security", "find-identity", "-p", "codesigning"]).decode()
    return {m.group(1): m.group(2) for m in re.finditer(r'^\s*\d+\) ([0-9A-F]{40}) "(.*)"', out, re.M)}


def normalized(serial):
    return serial.upper().lstrip("0")


def serial_number(sha1):
    out = run(["security", "find-certificate", "-a", "-Z", "-p"]).decode()
    for digest, pem in re.findall(r"SHA-1 hash: ([0-9A-F]{40})\n(-----BEGIN CERTIFICATE-----.*?-----END CERTIFICATE-----)", out, re.S):
        if digest == sha1:
            return normalized(run(["openssl", "x509", "-noout", "-serial"], pem.encode()).decode().strip().split("=", 1)[1])
    raise LookupError(f"no certificate with SHA-1 {sha1} in the keychain")


def b64url(data):
    return base64.urlsafe_b64encode(data).rstrip(b"=").decode()


def raw_signature(der):
    """openssl writes an ECDSA signature as DER (a SEQUENCE of two INTEGERs); ES256 wants r and s as 32 bytes each."""
    def length(i):
        if der[i] < 0x80:
            return der[i], i + 1
        size = der[i] & 0x7F
        return int.from_bytes(der[i + 1:i + 1 + size], "big"), i + 1 + size

    if der[0] != 0x30:
        raise ValueError("not a DER signature")
    _, i = length(1)
    parts = []
    for _ in range(2):
        if der[i] != 0x02:
            raise ValueError("not a DER signature")
        size, i = length(i + 1)
        parts.append(int.from_bytes(der[i:i + size], "big").to_bytes(32, "big"))
        i += size
    return b"".join(parts)


def token(key_file, key_id, issuer_id, now=None):
    """A 10-minute App Store Connect token (Apple allows up to 20)."""
    now = int(time.time()) if now is None else now
    header = b64url(json.dumps({"alg": "ES256", "kid": key_id, "typ": "JWT"}).encode())
    claims = b64url(json.dumps({"iss": issuer_id, "iat": now, "exp": now + 600, "aud": "appstoreconnect-v1"}).encode())
    signing_input = f"{header}.{claims}".encode()
    signature = raw_signature(run(["openssl", "dgst", "-sha256", "-sign", key_file], signing_input))
    return f"{header}.{claims}.{b64url(signature)}"


def call(method, path_or_url, bearer):
    url = path_or_url if path_or_url.startswith("https://") else API + path_or_url
    path = urllib.parse.urlsplit(url).path
    request = urllib.request.Request(url, method=method, headers={"Authorization": f"Bearer {bearer}"})
    try:
        with urllib.request.urlopen(request, timeout=30) as response:
            body = response.read()
    except urllib.error.HTTPError as error:
        detail = error.read().decode(errors="replace")
        try:
            detail = "; ".join(e.get("detail") or e.get("title", "") for e in json.loads(detail)["errors"])
        except (ValueError, KeyError, TypeError):
            pass
        raise RuntimeError(f"{method} {path} returned HTTP {error.code}: {detail}") from None
    return json.loads(body) if body else None


def snapshot(path):
    with open(path, "w") as f:
        f.write("\n".join(sorted(identities())) + "\n")


def certificates_in_account(bearer):
    query = urllib.parse.urlencode({"limit": 200, "fields[certificates]": "serialNumber,certificateType"})
    page, found = f"/certificates?{query}", {}
    while page:
        response = call("GET", page, bearer)
        found.update({normalized(c["attributes"]["serialNumber"]): c for c in response["data"]})
        page = response.get("links", {}).get("next")
    return found


def revoke(path):
    with open(path) as f:
        before = set(f.read().split())
    created = []
    for sha1, name in identities().items():
        if sha1 in before or not name.startswith(SIGNING_NAMES):
            continue
        if API_CREATED in name:
            created.append(sha1)
        else:
            warn(f"left alone a signing identity that appeared during the build but was not created by the key: {sha1}")
    if not created:
        print("no signing certificate was created during the build")
        return 0

    for name in ("ASC_KEY_FILE", "ASC_KEY_ID", "ASC_ISSUER_ID"):
        if not os.environ.get(name):
            print(f"error: {name} is not set", file=sys.stderr)
            return 1
    bearer = token(os.environ["ASC_KEY_FILE"], os.environ["ASC_KEY_ID"], os.environ["ASC_ISSUER_ID"])
    in_account = certificates_in_account(bearer)

    failed = False
    for sha1 in created:
        try:
            serial = serial_number(sha1)
            certificate = in_account.get(serial)
            if certificate is None:
                raise LookupError(f"the certificate with serial {serial} that the build created is not in the developer account")
            call("DELETE", f"/certificates/{certificate['id']}", bearer)
            print(f"revoked the {certificate['attributes']['certificateType']} certificate with serial {serial}, which the build created")
        except (RuntimeError, LookupError, ValueError) as error:
            print(f"error: {error}", file=sys.stderr)
            failed = True
    return 1 if failed else 0


def main(argv):
    if len(argv) != 3 or argv[1] not in ("snapshot", "revoke"):
        print(__doc__, file=sys.stderr)
        return 2
    if argv[1] == "snapshot":
        snapshot(argv[2])
        return 0
    try:
        return revoke(argv[2])
    except (RuntimeError, LookupError, ValueError, KeyError, OSError) as error:
        print(f"error: {error}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
