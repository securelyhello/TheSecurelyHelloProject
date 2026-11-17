#!/usr/bin/env python3
"""
file_to_string.py

A reversible FILE <-> STRING algorithm:

    FILE  -> read bytes -> compress (if it helps) -> hash (SHA-256)
          -> encode to text (base64 or base45) -> wrap in a small header
          -> STRING

    STRING -> parse header -> decode text -> decompress (if flagged)
           -> verify hash -> FILE

Also includes an optional chunking layer (session id + index/total) so a
long string can be split into transport-sized pieces (e.g. one per QR
code) and reassembled out of order on the receiving end.

No server / network required anywhere in this pipeline.

Simplest usage (interactive, no arguments needed):
    python file_to_string.py
    -> asks for a file path, gives you back a string to copy
    -> or paste a string back in, gives you back the file

Power-user usage (explicit subcommands):
    python file_to_string.py encode myphoto.png -o encoded.txt
    python file_to_string.py decode encoded.txt -o restored/
    python file_to_string.py chunk encoded.txt --size 400 -o chunks/
    python file_to_string.py unchunk chunks/ -o encoded_rebuilt.txt
"""

import argparse
import base64
import gzip
import hashlib
import json
import os
import sys
import uuid
from pathlib import Path

try:
    import pyperclip  # optional: auto-copy/paste via system clipboard
    _HAVE_CLIPBOARD = True
except ImportError:
    _HAVE_CLIPBOARD = False

# --------------------------------------------------------------------------
# 1. Base45 codec (RFC 9285) -- denser than Base64 inside QR alphanumeric mode
# --------------------------------------------------------------------------

_B45_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZ $%*+-./:"
_B45_INDEX = {c: i for i, c in enumerate(_B45_ALPHABET)}


def base45_encode(data: bytes) -> str:
    out = []
    length = len(data)
    for i in range(0, length - 1, 2):
        n = data[i] * 256 + data[i + 1]
        c = n % 45
        n //= 45
        d = n % 45
        e = n // 45
        out.append(_B45_ALPHABET[c])
        out.append(_B45_ALPHABET[d])
        out.append(_B45_ALPHABET[e])
    if length % 2 == 1:
        n = data[-1]
        c = n % 45
        d = n // 45
        out.append(_B45_ALPHABET[c])
        out.append(_B45_ALPHABET[d])
    return "".join(out)


def base45_decode(s: str) -> bytes:
    out = bytearray()
    n_full_triplets = len(s) // 3
    for i in range(n_full_triplets):
        chunk = s[i * 3 : i * 3 + 3]
        try:
            c, d, e = (_B45_INDEX[ch] for ch in chunk)
        except KeyError as exc:
            raise ValueError(f"Invalid base45 character: {exc}")
        n = c + d * 45 + e * 45 * 45
        if n > 0xFFFF:
            raise ValueError("Invalid base45 triplet (out of range)")
        out.append(n // 256)
        out.append(n % 256)
    rem = len(s) % 3
    tail = s[n_full_triplets * 3 :]
    if rem == 2:
        c, d = _B45_INDEX[tail[0]], _B45_INDEX[tail[1]]
        n = c + d * 45
        if n > 0xFF:
            raise ValueError("Invalid base45 pair (out of range)")
        out.append(n)
    elif rem == 1:
        raise ValueError("Invalid base45 string length")
    return bytes(out)


# --------------------------------------------------------------------------
# 2. Core encode: FILE -> STRING
# --------------------------------------------------------------------------

MAGIC = "FTS1"  # File-To-String, version 1
SUPPORTED_ENCODINGS = ("base64", "base45")


def encode_file(path: str, encoding: str = "base64", compress: bool = True) -> str:
    """Read a file and return a single self-describing reversible string."""
    if encoding not in SUPPORTED_ENCODINGS:
        raise ValueError(f"encoding must be one of {SUPPORTED_ENCODINGS}")

    raw = Path(path).read_bytes()
    original_size = len(raw)
    sha256 = hashlib.sha256(raw).hexdigest()

    payload_bytes = raw
    used_compression = False
    if compress:
        compressed = gzip.compress(raw, compresslevel=9)
        if len(compressed) < len(raw):
            payload_bytes = compressed
            used_compression = True

    if encoding == "base64":
        payload_text = base64.b64encode(payload_bytes).decode("ascii")
    else:  # base45
        payload_text = base45_encode(payload_bytes)

    meta = {
        "filename": Path(path).name,
        "size": original_size,
        "sha256": sha256,
        "compressed": used_compression,
        "encoding": encoding,
    }
    meta_b64 = base64.urlsafe_b64encode(json.dumps(meta, separators=(",", ":")).encode()).decode("ascii")

    # '|' cannot appear in base64/base45/urlsafe-base64 alphabets, so it's a
    # safe delimiter even though the payload itself is not escaped.
    return f"{MAGIC}|{meta_b64}|{payload_text}"


# --------------------------------------------------------------------------
# 3. Core decode: STRING -> FILE
# --------------------------------------------------------------------------

def decode_string(s: str, output_dir: str = ".") -> str:
    """Reverse of encode_file(). Writes the restored file and returns its path."""
    try:
        magic, meta_b64, payload_text = s.split("|", 2)
    except ValueError:
        raise ValueError("Malformed string: expected 'MAGIC|meta|payload'")

    if magic != MAGIC:
        raise ValueError(f"Unrecognized format magic: {magic!r}")

    meta = json.loads(base64.urlsafe_b64decode(meta_b64.encode()).decode())

    if meta["encoding"] == "base64":
        payload_bytes = base64.b64decode(payload_text)
    elif meta["encoding"] == "base45":
        payload_bytes = base45_decode(payload_text)
    else:
        raise ValueError(f"Unknown encoding in metadata: {meta['encoding']}")

    raw = gzip.decompress(payload_bytes) if meta["compressed"] else payload_bytes

    if len(raw) != meta["size"]:
        raise ValueError(f"Size mismatch: expected {meta['size']}, got {len(raw)}")

    actual_hash = hashlib.sha256(raw).hexdigest()
    if actual_hash != meta["sha256"]:
        raise ValueError(
            f"Integrity check failed: expected sha256 {meta['sha256']}, got {actual_hash}"
        )

    out_dir = Path(output_dir)
    out_dir.mkdir(parents=True, exist_ok=True)
    out_path = out_dir / meta["filename"]
    out_path.write_bytes(raw)
    return str(out_path)


# --------------------------------------------------------------------------
# 4. Optional chunking layer, for size-limited transports (e.g. QR codes)
# --------------------------------------------------------------------------

def chunk_string(s: str, chunk_size: int = 400):
    """
    Split an encoded string into transport-sized, self-describing chunks.
    Each chunk carries a session id + index/total, so chunks can arrive out
    of order and still be reassembled, and missing indices can be re-requested
    individually instead of resending everything.
    """
    session_id = uuid.uuid4().hex[:8]
    pieces = [s[i : i + chunk_size] for i in range(0, len(s), chunk_size)]
    total = len(pieces)
    return [f"{MAGIC}C|{session_id}|{i + 1}/{total}|{piece}" for i, piece in enumerate(pieces)]


def reassemble_chunks(chunks) -> str:
    """Reverse of chunk_string(). Accepts chunks in any order."""
    parsed = []
    session_ids = set()
    total_expected = None

    for c in chunks:
        magic, session_id, idx_total, piece = c.split("|", 3)
        if magic != f"{MAGIC}C":
            raise ValueError(f"Not a chunk record: {magic!r}")
        idx_str, total_str = idx_total.split("/")
        idx, total = int(idx_str), int(total_str)
        session_ids.add(session_id)
        total_expected = total
        parsed.append((idx, piece))

    if len(session_ids) > 1:
        raise ValueError(f"Chunks from multiple sessions mixed together: {session_ids}")
    if len(parsed) != total_expected:
        have = sorted(idx for idx, _ in parsed)
        missing = sorted(set(range(1, total_expected + 1)) - set(have))
        raise ValueError(f"Missing chunk(s): {missing}")

    parsed.sort(key=lambda t: t[0])
    return "".join(piece for _, piece in parsed)


# --------------------------------------------------------------------------
# 5. Interactive mode -- "give me a file path, give me back a string" and
#    "give me a string, give me back the file where I want it"
# --------------------------------------------------------------------------

# Above this many characters, don't dump the string to the terminal --
# printing/pasting that much text in a shell is unreliable. Save it to a
# .txt file next to the source file instead.
_INLINE_DISPLAY_LIMIT = 4000


def _interactive_encode():
    path = input("Path to the file you want to convert: ").strip().strip('"').strip("'")
    path = os.path.expanduser(path)
    if not os.path.isfile(path):
        print(f"✗ No such file: {path}")
        return

    encoding = input("Encoding [base64 (default) / base45]: ").strip().lower() or "base64"
    if encoding not in SUPPORTED_ENCODINGS:
        print(f"✗ Unknown encoding {encoding!r}, using base64.")
        encoding = "base64"

    s = encode_file(path, encoding=encoding)
    print(f"\n✔ Converted. String is {len(s):,} characters long.\n")

    copied = False
    if _HAVE_CLIPBOARD:
        try:
            pyperclip.copy(s)
            copied = True
            print("✔ Copied to your clipboard — just paste it wherever you want to send it.")
        except Exception:
            copied = False

    if len(s) <= _INLINE_DISPLAY_LIMIT:
        print("\n----- COPY EVERYTHING BETWEEN THE LINES -----")
        print(s)
        print("----- END -----\n")
    else:
        out_path = str(Path(path).with_suffix(Path(path).suffix + ".encoded.txt"))
        Path(out_path).write_text(s)
        print(f"(String is long, so it's also saved to a file for easy copying: {out_path})")
        if not copied:
            print("Open that file and copy its full contents.")


def _interactive_decode():
    raw = input(
        "Paste the string here, OR type the path to a .txt file that contains it: "
    ).strip()

    if os.path.isfile(raw):
        s = Path(raw).read_text().strip()
    else:
        s = raw
        if not s and _HAVE_CLIPBOARD:
            try:
                s = pyperclip.paste().strip()
                print("(using clipboard contents)")
            except Exception:
                pass

    if not s:
        print("✗ Nothing to decode.")
        return

    dest = input(
        "Where do you want the file saved? (press Enter for current folder): "
    ).strip().strip('"').strip("'") or "."
    dest = os.path.expanduser(dest)

    try:
        out_path = decode_string(s, output_dir=dest)
    except Exception as exc:
        print(f"✗ Could not restore file: {exc}")
        return

    print(f"\n✔ File restored at: {out_path}")


def run_interactive():
    print("=== File <-> String Converter ===")
    print("1. Convert a file into a string (to copy/send)")
    print("2. Convert a string back into a file")
    choice = input("Choose 1 or 2: ").strip()
    if choice == "1":
        _interactive_encode()
    elif choice == "2":
        _interactive_decode()
    else:
        print("✗ Please enter 1 or 2.")


# --------------------------------------------------------------------------
# 6. CLI
# --------------------------------------------------------------------------

def _cmd_encode(args):
    s = encode_file(args.input, encoding=args.encoding, compress=not args.no_compress)
    if args.o:
        Path(args.o).write_text(s)
        print(f"Encoded -> {args.o}  ({len(s)} chars)")
    else:
        print(s)


def _cmd_decode(args):
    s = Path(args.input).read_text()
    out_path = decode_string(s, output_dir=args.o or ".")
    print(f"Restored -> {out_path}")


def _cmd_chunk(args):
    s = Path(args.input).read_text()
    chunks = chunk_string(s, chunk_size=args.size)
    out_dir = Path(args.o or "chunks")
    out_dir.mkdir(parents=True, exist_ok=True)
    for i, c in enumerate(chunks, 1):
        (out_dir / f"chunk_{i:04d}.txt").write_text(c)
    print(f"Wrote {len(chunks)} chunk(s) -> {out_dir}/")


def _cmd_unchunk(args):
    chunk_dir = Path(args.input)
    chunk_files = sorted(chunk_dir.glob("chunk_*.txt"))
    if not chunk_files:
        print("No chunk_*.txt files found.", file=sys.stderr)
        sys.exit(1)
    chunks = [f.read_text() for f in chunk_files]
    s = reassemble_chunks(chunks)
    out_path = args.o or "rebuilt.txt"
    Path(out_path).write_text(s)
    print(f"Reassembled -> {out_path}")


def main():
    if len(sys.argv) == 1:
        run_interactive()
        return

    p = argparse.ArgumentParser(description="Reversible file <-> string converter")
    sub = p.add_subparsers(dest="command", required=True)

    pe = sub.add_parser("encode", help="file -> string")
    pe.add_argument("input", help="path to input file")
    pe.add_argument("-o", help="write string to this path instead of stdout")
    pe.add_argument("--encoding", choices=SUPPORTED_ENCODINGS, default="base64")
    pe.add_argument("--no-compress", action="store_true", help="skip gzip step")
    pe.set_defaults(func=_cmd_encode)

    pd = sub.add_parser("decode", help="string -> file")
    pd.add_argument("input", help="path to a file containing the encoded string")
    pd.add_argument("-o", help="output directory (default: current dir)")
    pd.set_defaults(func=_cmd_decode)

    pc = sub.add_parser("chunk", help="split an encoded string into transport-sized pieces")
    pc.add_argument("input", help="path to a file containing the encoded string")
    pc.add_argument("--size", type=int, default=400, help="chars per chunk")
    pc.add_argument("-o", help="output directory for chunk files (default: chunks/)")
    pc.set_defaults(func=_cmd_chunk)

    pu = sub.add_parser("unchunk", help="reassemble chunk files back into the encoded string")
    pu.add_argument("input", help="directory containing chunk_*.txt files")
    pu.add_argument("-o", help="output path for rebuilt string file (default: rebuilt.txt)")
    pu.set_defaults(func=_cmd_unchunk)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()