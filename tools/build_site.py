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
    '06b_invite', '10_chats_unread', '12b_chat_attachments', '12c_reply_react_edit_delete',
    '14_contact_info', '17b_linked_devices', '17c_settings_security', '19_wide_chat_open',
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
  <meta http-equiv="Content-Security-Policy" content="default-src 'self'; img-src 'self'; style-src 'self'; script-src 'self'; base-uri 'none'; form-action 'none'">
  <meta name="referrer" content="no-referrer">
  <title>{title} · Securely Hello</title>
  <link rel="icon" href="assets/logo.svg" type="image/svg+xml">
  <link rel="stylesheet" href="styles.css">
</head>
<body>
  <header class="nav"><div class="wrap nav-inner">
    <a class="brand" href="index.html"><img src="assets/logo.svg" alt="" width="32" height="32"><span>Securely Hello</span></a>
  </div></header>
  <main class="page"><div class="wrap narrow">
<!-- Generated from {source} by tools/build_site.py. Edit the Markdown, not this file. -->
{body}
  </div></main>
</body>
</html>
"""


def build_legal():
    for name, title in (('privacy', 'Privacy policy'), ('terms', 'Terms of service')):
        src = os.path.join(ROOT, 'docs', 'legal', f'{name}.md')
        with open(src, encoding='utf-8') as f:
            body = markdown_to_html(f.read())
        with open(os.path.join(SITE, f'{name}.html'), 'w', encoding='utf-8') as f:
            f.write(PAGE.format(title=title, source=f'docs/legal/{name}.md', body=body))
        print(f'wrote website/{name}.html')


def copy_shots(shot_dir):
    dest = os.path.join(SITE, 'assets', 'screens')
    os.makedirs(dest, exist_ok=True)
    missing = [s for s in SCREENS if not os.path.exists(os.path.join(shot_dir, f'{s}.png'))]
    if missing:
        sys.exit(f'missing screenshots in {shot_dir}: {", ".join(missing)}')
    for s in SCREENS:
        shutil.copyfile(os.path.join(shot_dir, f'{s}.png'), os.path.join(dest, f'{s}.png'))
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
