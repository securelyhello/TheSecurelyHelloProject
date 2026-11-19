#!/usr/bin/env python3
"""Publishes a signed release APK for the website and the in-app updater.

  flutter build apk --release
  tools/release_apk.py build/app/outputs/flutter-apk/app-release.apk \\
      --notes "Stories, a new look and faster hang-ups."

Writes (website/download/ is git-ignored; copy it to the server with the site):

  website/download/securelyhello-<versionName>.apk   this release
  website/download/securelyhello.apk                 the same file, for the site's button
  website/download/latest.json                       what the app checks (lib/core/update/)

The version comes from pubspec.yaml (version: <name>+<code>). The APK's
signing certificate is checked against apkCertSha256 in website/config.js
with apksigner (from $ANDROID_HOME/build-tools) when it can be found; a
mismatch stops here, because the app refuses an update signed with another
key anyway. Nothing here uses the network.
"""
import argparse
import glob
import hashlib
import json
import os
import re
import shutil
import subprocess
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, 'website')
DEFAULT_BASE = 'https://securelyhello.thenn.in'


def pubspec_version(path=os.path.join(ROOT, 'pubspec.yaml')):
    with open(path, encoding='utf-8') as f:
        m = re.search(r'^version:\s*([0-9][^+\s]*)\+(\d+)\s*$', f.read(), re.M)
    if not m:
        sys.exit('pubspec.yaml has no "version: <name>+<code>" line')
    return m.group(1), int(m.group(2))


def site_cert(path=os.path.join(SITE, 'config.js')):
    with open(path, encoding='utf-8') as f:
        m = re.search(r"apkCertSha256:\s*'([0-9A-Fa-f:]+)'", f.read())
    return m.group(1).upper() if m else None


def apk_cert(apk):
    """SHA-256 of the APK's signing certificate (AA:BB:…), or None without apksigner."""
    home = os.environ.get('ANDROID_HOME') or os.environ.get('ANDROID_SDK_ROOT') or ''
    tools = sorted(glob.glob(os.path.join(home, 'build-tools', '*', 'apksigner')))
    signer = shutil.which('apksigner') or (tools[-1] if tools else None)
    if not signer:
        return None
    out = subprocess.run([signer, 'verify', '--print-certs', apk], capture_output=True, text=True)
    if out.returncode != 0:
        sys.exit(f'apksigner could not verify {apk}:\n{out.stderr}')
    m = re.search(r'certificate SHA-256 digest:\s*([0-9a-f]{64})', out.stdout)
    if not m:
        sys.exit('apksigner printed no certificate digest')
    hex_ = m.group(1).upper()
    return ':'.join(hex_[i:i + 2] for i in range(0, 64, 2))


def sha256_file(path):
    h = hashlib.sha256()
    with open(path, 'rb') as f:
        for block in iter(lambda: f.read(1 << 20), b''):
            h.update(block)
    return h.hexdigest()


def manifest(version_name, version_code, url, sha256, min_code, notes):
    if min_code > version_code:
        sys.exit('--min-supported cannot be above the version being published')
    if len(notes) > 2000:
        sys.exit('--notes is limited to 2000 characters (the app refuses more)')
    return {
        'versionCode': version_code,
        'versionName': version_name,
        'url': url,
        'sha256': sha256,
        'minSupportedVersionCode': min_code,
        'notes': notes,
    }


def main(argv=None):
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('apk')
    ap.add_argument('--notes', default='', help='shown in the app\'s "Update available" card')
    ap.add_argument('--min-supported', type=int, default=1,
                    help='versionCode below which the app blocks until updated (default 1: nobody)')
    ap.add_argument('--base-url', default=DEFAULT_BASE)
    ap.add_argument('--out', default=os.path.join(SITE, 'download'))
    ap.add_argument('--skip-cert-check', action='store_true', help='only for test builds')
    args = ap.parse_args(argv)

    name, code = pubspec_version()
    if not args.skip_cert_check:
        want, got = site_cert(), apk_cert(args.apk)
        if got is None:
            print('warning: apksigner not found; signing certificate not checked', file=sys.stderr)
        elif want and got != want:
            sys.exit(f'{args.apk} is signed with {got}\nbut the site says {want} (website/config.js)')
    os.makedirs(args.out, exist_ok=True)
    filename = f'securelyhello-{name}.apk'
    dest = os.path.join(args.out, filename)
    shutil.copyfile(args.apk, dest)
    shutil.copyfile(args.apk, os.path.join(args.out, 'securelyhello.apk'))
    data = manifest(name, code, f'{args.base_url.rstrip("/")}/download/{filename}', sha256_file(dest),
                    args.min_supported, args.notes)
    with open(os.path.join(args.out, 'latest.json'), 'w', encoding='utf-8') as f:
        json.dump(data, f, indent=2)
        f.write('\n')
    print(json.dumps(data, indent=2))


if __name__ == '__main__':
    main()
