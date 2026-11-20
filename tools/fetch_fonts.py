#!/usr/bin/env python3
"""Fetch the Chillax font files used by the app and the website.

Chillax is licensed (ITF Free Font License, Fontshare) for embedding in our
app and self-hosting on our site, but the license forbids redistributing the
font files, so they are not committed to this public repository. Run this
script once before building; it downloads the official Fontshare package and
copies the files into place:

    assets/fonts/Chillax-Medium.ttf            (Flutter app)
    assets/fonts/Chillax-Semibold.ttf          (Flutter app)
    assets/fonts/FFL-Chillax.txt               (license)
    website/assets/fonts/Chillax-Medium.woff2  (website)
    website/assets/fonts/Chillax-Semibold.woff2 (website)
    website/assets/fonts/FFL-Chillax.txt       (license)

Every copied file is checked against the SHA-256 constants below. If the
download does not match, nothing is written and the script exits non-zero.
If all six files already exist with the expected hashes, nothing is
downloaded.

Standard library only.
"""

import hashlib
import os
import shutil
import sys
import tempfile
import urllib.error
import urllib.request
import zipfile

URL = "https://api.fontshare.com/v2/fonts/download/chillax"
USER_AGENT = "SecurelyHello-build/1.0"

REPO_ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Limits, so a hijacked or broken download can't fill the disk.
MAX_DOWNLOAD_BYTES = 20 * 1024 * 1024
MAX_MEMBER_BYTES = 5 * 1024 * 1024

LICENSE_MEMBER = "Chillax_Complete/License/FFL.txt"

# (zip member, destination relative to the repo root, SHA-256)
TARGETS = [
    (
        "Chillax_Complete/Fonts/WEB/fonts/Chillax-Medium.ttf",
        "assets/fonts/Chillax-Medium.ttf",
        "f3f6dda43bda92bfc237f02e3ffbf9de052facbcc51e3e3a6047907d23f31751",
    ),
    (
        "Chillax_Complete/Fonts/WEB/fonts/Chillax-Semibold.ttf",
        "assets/fonts/Chillax-Semibold.ttf",
        "ea44f4823df8f4c1929127cf8f2f2a8aae824302cec582b8a19c5eb37c517f62",
    ),
    (
        "Chillax_Complete/Fonts/WEB/fonts/Chillax-Medium.woff2",
        "website/assets/fonts/Chillax-Medium.woff2",
        "afaf7e5fc33a5db46eb97ec9162ca86dbf07118c3a9acc8e33834a04740bef02",
    ),
    (
        "Chillax_Complete/Fonts/WEB/fonts/Chillax-Semibold.woff2",
        "website/assets/fonts/Chillax-Semibold.woff2",
        "16cc2b75ef71f81aa3cd47792a8d349719c335a91e8787eb229aea5de279740a",
    ),
]

LICENSE_SHA256 = "145e7fe2429a3336ba215c070ef722000e01348a3e1baaa127e871bb5012f554"
LICENSE_DEST = "FFL-Chillax.txt"
LICENSE_DESTS = [
    "assets/fonts/FFL-Chillax.txt",
    "website/assets/fonts/FFL-Chillax.txt",
]


def sha256_of(path):
    digest = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 16), b""):
            digest.update(chunk)
    return digest.hexdigest()


def expected_outputs():
    """Yield (repo-relative destination, expected SHA-256) for all six files."""
    for _member, dest, sha in TARGETS:
        yield dest, sha
    for dest in LICENSE_DESTS:
        yield dest, LICENSE_SHA256


def already_present():
    for dest, sha in expected_outputs():
        path = os.path.join(REPO_ROOT, dest)
        if not os.path.isfile(path) or sha256_of(path) != sha:
            return False
    return True


def download(dest_zip):
    request = urllib.request.Request(URL, headers={"User-Agent": USER_AGENT})
    try:
        with urllib.request.urlopen(request, timeout=60) as response, open(dest_zip, "wb") as out:
            declared = response.headers.get("Content-Length")
            if declared is not None and declared.isdigit() and int(declared) > MAX_DOWNLOAD_BYTES:
                raise SystemExit(
                    f"fetch_fonts: the download is {declared} bytes; refusing more than {MAX_DOWNLOAD_BYTES}"
                )
            received = 0
            while True:
                chunk = response.read(1 << 16)
                if not chunk:
                    break
                received += len(chunk)
                if received > MAX_DOWNLOAD_BYTES:
                    raise SystemExit(
                        f"fetch_fonts: the download is larger than {MAX_DOWNLOAD_BYTES} bytes; aborted"
                    )
                out.write(chunk)
    except (urllib.error.URLError, OSError) as exc:
        raise SystemExit(f"fetch_fonts: download from {URL} failed: {exc}")


def extract_and_verify(zip_path, work_dir):
    """Extract the needed members into work_dir and check their hashes.

    Returns a list of (extracted path, repo-relative destinations, sha256).
    Raises SystemExit with a clear message on any mismatch.
    """
    jobs = []
    with zipfile.ZipFile(zip_path) as archive:
        names = set(archive.namelist())
        wanted = [(member, [dest], sha) for member, dest, sha in TARGETS]
        wanted.append((LICENSE_MEMBER, LICENSE_DESTS, LICENSE_SHA256))
        for member, dests, sha in wanted:
            if member not in names:
                raise SystemExit(
                    f"fetch_fonts: {member} is missing from the Fontshare package; "
                    "the package layout may have changed"
                )
            size = archive.getinfo(member).file_size
            if size > MAX_MEMBER_BYTES:
                raise SystemExit(
                    f"fetch_fonts: {member} is {size} bytes; refusing more than {MAX_MEMBER_BYTES}"
                )
            # ZipFile.extract sanitises the member path, so it cannot escape work_dir.
            extracted = archive.extract(member, work_dir)
            actual = sha256_of(extracted)
            if actual != sha:
                raise SystemExit(
                    f"fetch_fonts: SHA-256 mismatch for {member}\n"
                    f"  expected {sha}\n"
                    f"  got      {actual}\n"
                    "Nothing was copied into the repository."
                )
            jobs.append((extracted, dests, sha))
    return jobs


def main():
    if already_present():
        print("fetch_fonts: all Chillax files are present and match; nothing to do.")
        return 0

    work_dir = tempfile.mkdtemp(prefix="securelyhello-fonts-")
    try:
        zip_path = os.path.join(work_dir, "chillax.zip")
        extract_dir = os.path.join(work_dir, "extract")
        os.mkdir(extract_dir)

        print(f"fetch_fonts: downloading {URL}")
        download(zip_path)
        jobs = extract_and_verify(zip_path, extract_dir)

        for extracted, dests, sha in jobs:
            for dest in dests:
                target = os.path.join(REPO_ROOT, dest)
                os.makedirs(os.path.dirname(target), exist_ok=True)
                tmp_target = target + ".part"
                shutil.copyfile(extracted, tmp_target)
                if sha256_of(tmp_target) != sha:
                    os.remove(tmp_target)
                    raise SystemExit(f"fetch_fonts: copy of {dest} failed verification")
                os.replace(tmp_target, target)
                print(f"fetch_fonts: wrote {dest}")
    finally:
        shutil.rmtree(work_dir, ignore_errors=True)

    print("fetch_fonts: done; all Chillax files verified.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
