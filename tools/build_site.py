#!/usr/bin/env python3
"""Builds the generated parts of website/.

  tools/build_site.py                 legal pages only (docs/legal -> website/*.html)
  tools/build_site.py --shots DIR     also copy screenshots from a UI test run:
      flutter test integration_test/ui_flow_test.dart -d linux --dart-define=SHOT_DIR=DIR
  tools/build_site.py --run-tests     also run the test suites and write
                                      website/assets/report.json
      --with-integration              include the integration tests (needs a running
                                      server, see README "Tests") and refresh the
                                      screenshots from the UI test

The rest of the site is hand-written; nothing here fetches from the network.
"""
import argparse
import datetime
import html
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SITE = os.path.join(ROOT, 'website')

# Screens the site shows (website/index.html references these names).
SCREENS = [
    '10_chats_unread', '12c_reply_react_edit_delete', '15c_group_chat', '13b_incoming_call',
    '16b_calls', '14_contact_info', '16d_story_viewer', '06_find_people_empty', '07_find_people_result',
]


def inline(text):
    """Escapes text, then applies **bold**, _italic_, `code` and [links](url)."""
    out = html.escape(text, quote=False)
    out = re.sub(r'`([^`]+)`', r'<code>\1</code>', out)
    out = re.sub(r'\*\*([^*]+)\*\*', r'<strong>\1</strong>', out)
    out = re.sub(r'(?<![\w])_([^_]+)_(?![\w])', r'<em>\1</em>', out)
    out = re.sub(r'\[([^\]]+)\]\((https?://[^)\s]+|mailto:[^)\s]+|[\w./#-]+)\)',
                 lambda m: f'<a href="{html.escape(m.group(2))}">{m.group(1)}</a>', out)
    return out


def markdown_to_html(md):
    """The subset the legal documents use: headings, paragraphs, lists, tables."""
    lines = md.splitlines()
    out, para, i = [], [], 0

    def flush():
        if para:
            out.append(f'<p>{inline(" ".join(para))}</p>')
            para.clear()

    while i < len(lines):
        line = lines[i].rstrip()
        if not line.strip():
            flush()
            i += 1
        elif line.startswith('#'):
            flush()
            level = len(line) - len(line.lstrip('#'))
            out.append(f'<h{level}>{inline(line[level:].strip())}</h{level}>')
            i += 1
        elif line.startswith('|'):
            flush()
            rows = []
            while i < len(lines) and lines[i].startswith('|'):
                rows.append([c.strip() for c in lines[i].strip().strip('|').split('|')])
                i += 1
            head, body = rows[0], [r for r in rows[1:] if not all(set(c) <= set('-: ') for c in r)]
            out.append('<table><thead><tr>' + ''.join(f'<th>{inline(c)}</th>' for c in head) + '</tr></thead><tbody>')
            out.extend('<tr>' + ''.join(f'<td>{inline(c)}</td>' for c in r) + '</tr>' for r in body)
            out.append('</tbody></table>')
        elif re.match(r'^\s*([-*]|\d+\.)\s', line):
            flush()
            ordered = bool(re.match(r'^\s*\d+\.', line))
            items = []
            while i < len(lines) and lines[i].strip():
                l = lines[i]
                if re.match(r'^\s*([-*]|\d+\.)\s', l):
                    items.append(re.sub(r'^\s*([-*]|\d+\.)\s', '', l).strip())
                else:
                    items[-1] += ' ' + l.strip()
                i += 1
            tag = 'ol' if ordered else 'ul'
            out.append(f'<{tag}>' + ''.join(f'<li>{inline(t)}</li>' for t in items) + f'</{tag}>')
        else:
            para.append(line.strip())
            i += 1
    flush()
    return '\n'.join(out)


PAGE = """<!doctype html>
<html lang="en">
<head>
  <meta charset="utf-8">
  <meta name="viewport" content="width=device-width, initial-scale=1">
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; font-src 'self'; base-uri 'none'; form-action 'none'">
  <meta name="referrer" content="no-referrer">
  <title>{title}, Securely Hello</title>
  <meta name="description" content="{description}">
  <meta name="theme-color" content="#F7F5EC">
  <link rel="icon" href="assets/logo.svg" type="image/svg+xml">
  <link rel="icon" href="assets/favicon-32.png" sizes="32x32" type="image/png">
  <link rel="preload" href="assets/fonts/Chillax-Semibold.woff2" as="font" type="font/woff2" crossorigin>
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <header class="nav" id="nav">
    <div class="container">
      <div class="nav-pill">
        <a class="brand" href="index.html" aria-label="Securely Hello home"><img src="assets/logo.svg" alt="" width="32" height="32"><span>Securely Hello</span></a>
        <nav aria-label="Legal" class="nav-links"><a href="privacy.html">Privacy</a><a href="terms.html">Terms</a></nav>
        <a class="btn btn--primary btn--nav" href="index.html#get">Download</a>
      </div>
    </div>
  </header>
  <main class="page container" id="main">
<!-- Generated from {source} by tools/build_site.py. Edit the Markdown, not this file. -->
{body}
  </main>
  <footer class="footer">
    <div class="footer-ink">
    <div class="container footer-inner">
      <p class="footer-statement">Not even we can read your chats.</p>
      <div class="footer-bar">
        <a class="brand" href="index.html"><img src="assets/logo.svg" alt="" width="28" height="28"><span>Securely Hello</span></a>
        <nav aria-label="Footer"><a href="privacy.html">Privacy</a><a href="terms.html">Terms</a><a href="mailto:hello@thenn.in">hello@thenn.in</a></nav>
      </div>
    </div>
    </div>
  </footer>
</body>
</html>
"""

DESCRIPTIONS = {
    'privacy': 'What the Securely Hello app and server keep, why, and for how long.',
    'terms': 'The rules for using Securely Hello.',
}


def layout_legal(body):
    """Lays the document out as one article: a head (the title and what comes before the first
    heading) and one row per section: its heading, then its text. Tables get a
    scrolling wrapper so they never widen the page on a phone."""
    body = re.sub(r'(<table>.*?</table>)',
                  r'<div class="table-wrap" role="region" aria-label="Table" tabindex="0">\1</div>',
                  body, flags=re.S)
    head, *sections = re.split(r'(?=<h2>)', body)
    out = ['<article class="legal">', '<header class="legal-head">', head.strip(), '</header>']
    for sec in sections:
        h2, _, rest = sec.partition('</h2>')
        out.append(f'<div class="legal-sec">{h2}</h2>\n<div class="legal-body">\n{rest.strip()}\n</div></div>')
    out.append('</article>')
    return '\n'.join(out)


def build_legal():
    for name, title in (('privacy', 'Privacy policy'), ('terms', 'Terms of service')):
        src = os.path.join(ROOT, 'docs', 'legal', f'{name}.md')
        with open(src, encoding='utf-8') as f:
            body = markdown_to_html(f.read())
        with open(os.path.join(SITE, f'{name}.html'), 'w', encoding='utf-8') as f:
            f.write(PAGE.format(title=title, source=f'docs/legal/{name}.md',
                                description=DESCRIPTIONS[name], body=layout_legal(body)))
        print(f'wrote website/{name}.html')


def copy_shots(shot_dir):
    dest = os.path.join(SITE, 'assets', 'screens')
    os.makedirs(dest, exist_ok=True)
    missing = [s for s in SCREENS if not os.path.exists(os.path.join(shot_dir, f'{s}.png'))]
    if missing:
        sys.exit(f'missing screenshots in {shot_dir}: {", ".join(missing)}')
    from PIL import Image  # pip install pillow
    for s in SCREENS:
        src = os.path.join(shot_dir, f'{s}.png')
        shutil.copyfile(src, os.path.join(dest, f'{s}.png'))
        # The page shows WebP (a fraction of the size); the PNG stays for reference.
        Image.open(src).convert('RGB').save(os.path.join(dest, f'{s}.webp'), 'WEBP', quality=82, method=6)
    print(f'copied {len(SCREENS)} screenshots')


def run(cmd, cwd):
    print('$', ' '.join(cmd), f'(in {os.path.relpath(cwd, ROOT) or "."})', flush=True)
    res = subprocess.run(cmd, cwd=cwd, capture_output=True, text=True)
    return res.stdout + res.stderr


def flutter_counts(output):
    m = re.findall(r'\+(\d+)(?: ~\d+)?(?: -(\d+))?: (?:All tests passed|Some tests failed)', output)
    if not m:
        return 0, 1
    passed, failed = m[-1]
    return int(passed), int(failed or 0)


def node_counts(output):
    p = re.search(r'^# pass (\d+)', output, re.M)
    f = re.search(r'^# fail (\d+)', output, re.M)
    return (int(p.group(1)) if p else 0), (int(f.group(1)) if f else 1)


def run_tests(with_integration):
    suites = []
    server = os.path.join(ROOT, 'server')
    p, f = node_counts(run(['npm', 'test'], server))
    suites.append({'name': 'server tests', 'passed': p, 'failed': f,
                   'what': 'API, devices, relay, 2FA, spam, invites, fuzzing'})
    p, f = flutter_counts(run(['flutter', 'test'], ROOT))
    suites.append({'name': 'app tests', 'passed': p, 'failed': f,
                   'what': 'ratchet, sessions, wire format, app lock, widgets, fuzzing'})
    if with_integration:
        # Headless machines: SITE_TEST_WRAPPER="xvfb-run -a dbus-run-session --".
        wrapper = os.environ.get('SITE_TEST_WRAPPER', '').split()
        defines = [f'--dart-define=MAIL_DIR={os.environ["MAIL_DIR"]}'] if os.environ.get('MAIL_DIR') else []
        shots = tempfile.mkdtemp(prefix='sh_shots_')
        for file, name, what, extra in (
            ('integration_test/e2e_chat_test.dart', 'end-to-end runs', 'real apps messaging through a real server', []),
            ('integration_test/ui_flow_test.dart', 'UI walkthrough', 'drives every screen, takes these screenshots',
             [f'--dart-define=SHOT_DIR={shots}']),
        ):
            p, f = flutter_counts(run(wrapper + ['flutter', 'test', file, '-d', 'linux', *defines, *extra], ROOT))
            suites.append({'name': name, 'passed': p, 'failed': f, 'what': what})
        if not suites[-1]['failed']:
            copy_shots(shots)
        shutil.rmtree(shots, ignore_errors=True)
    commit = subprocess.run(['git', 'rev-parse', '--short', 'HEAD'], cwd=ROOT,
                            capture_output=True, text=True).stdout.strip()
    report = {
        'generated_at': datetime.datetime.now(datetime.timezone.utc).isoformat(timespec='seconds'),
        'commit': commit,
        'suites': suites,
    }
    path = os.path.join(SITE, 'assets', 'report.json')
    with open(path, 'w', encoding='utf-8') as f:
        json.dump(report, f, indent=2)
        f.write('\n')
    print(json.dumps(report, indent=2))
    if any(s['failed'] for s in suites):
        sys.exit('some tests failed; the report shows it')


def main():
    ap = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    ap.add_argument('--shots', help='directory with screenshots from the UI test')
    ap.add_argument('--run-tests', action='store_true')
    ap.add_argument('--with-integration', action='store_true')
    args = ap.parse_args()
    build_legal()
    if args.shots:
        copy_shots(args.shots)
    if args.run_tests:
        run_tests(args.with_integration)


if __name__ == '__main__':
    main()
