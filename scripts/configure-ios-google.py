# SPDX-License-Identifier: Apache-2.0
"""Embed the public iOS OAuth client and its callback scheme in the app plist."""
import os
import plistlib
import re
from pathlib import Path

client = os.environ.get("GOOGLE_IOS_CLIENT_ID", "").strip()
if client:
    if not re.fullmatch(r"[\w-]+\.apps\.googleusercontent\.com", client):
        raise SystemExit("Invalid GOOGLE_IOS_CLIENT_ID")
    path = Path(__file__).resolve().parents[1] / "app/apps/desktop/src-tauri/gen/apple/desktop_iOS/Info.plist"
    plist = plistlib.loads(path.read_bytes())
    scheme = ".".join(reversed(client.split(".")))
    urls = plist.setdefault("CFBundleURLTypes", [])
    urls[:] = [entry for entry in urls if entry.get("CFBundleURLName") != "Google Drive"]
    urls.append({"CFBundleURLName": "Google Drive", "CFBundleURLSchemes": [scheme]})
    plist["GIDClientID"] = client
    path.write_bytes(plistlib.dumps(plist, sort_keys=False))
