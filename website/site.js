// Download links from config.js, and test results from assets/report.json
// (written by tools/build_site.py).
(function () {
  const site = window.SITE || {};

  let anyDownload = false;
  document.querySelectorAll('[data-link]').forEach((a) => {
    const url = site[a.dataset.link];
    if (url) {
      a.href = url;
      if (a.closest('#downloads')) anyDownload = true;
    } else {
      a.hidden = true;
    }
  });
  const apkNote = document.getElementById('apk-note');
  if (apkNote && site.androidApk && site.apkCertSha256) {
    document.getElementById('apk-cert').textContent = site.apkCertSha256;
    apkNote.hidden = false;
  }
  const apkHelp = document.getElementById('apk-help');
  if (apkHelp && site.androidApk) apkHelp.hidden = false;

  const soon = document.getElementById('downloads-soon');
  if (soon && !anyDownload) soon.hidden = false;

  if (site.contact) {
    document.querySelectorAll('.contact-email').forEach((el) => {
      const a = document.createElement('a');
      a.href = 'mailto:' + site.contact;
      a.textContent = site.contact;
      el.replaceWith(a);
    });
  }

  const year = document.getElementById('year');
  if (year) year.textContent = String(new Date().getFullYear());

  const stats = document.getElementById('stats');
  if (!stats) return;
  fetch('assets/report.json', { cache: 'no-store' })
    .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
    .then((report) => {
      stats.textContent = '';
      for (const s of report.suites || []) {
        const card = document.createElement('div');
        card.className = 'stat' + (s.failed ? ' fail' : '');
        const b = document.createElement('b');
        b.textContent = s.failed ? `${s.passed} / ${s.passed + s.failed}` : String(s.passed);
        const span = document.createElement('span');
        span.textContent = s.name;
        const small = document.createElement('small');
        small.textContent = s.failed ? `${s.failed} failing` : s.what || 'all passing';
        card.append(b, span, small);
        stats.append(card);
      }
      const meta = document.getElementById('stats-meta');
      if (meta && report.generated_at) {
        const when = new Date(report.generated_at).toLocaleDateString(undefined, { dateStyle: 'long' });
        meta.textContent = `Last run ${when}` + (report.commit ? `, commit ${report.commit}` : '') + '.';
      }
    })
    .catch(() => {
      stats.textContent = 'Test results are not available right now.';
    });
})();
