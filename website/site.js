// Download links from config.js, the current version from download/latest.json,
// scroll effects and the test count from assets/report.json. Same-origin only.
(function () {
  const site = window.SITE || {};
  const reduced = window.matchMedia('(prefers-reduced-motion: reduce)').matches;

  // Links: empty ones hide their button.
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
  const soon = document.getElementById('downloads-soon');
  if (soon && !anyDownload) soon.hidden = false;

  // The APK's signing certificate, with a copy button.
  const apkNote = document.getElementById('apk-note');
  if (apkNote && site.androidApk && site.apkCertSha256) {
    document.getElementById('apk-cert').textContent = site.apkCertSha256;
    apkNote.hidden = false;
    const copy = document.getElementById('copy-cert');
    if (copy && navigator.clipboard) {
      copy.addEventListener('click', () => {
        navigator.clipboard.writeText(site.apkCertSha256).then(() => {
          copy.textContent = 'Copied';
          setTimeout(() => { copy.textContent = 'Copy'; }, 1600);
        });
      });
    } else if (copy) {
      copy.hidden = true;
    }
  }
  const apkHelp = document.getElementById('apk-help');
  if (apkHelp && site.androidApk) apkHelp.hidden = false;

  // The version people will get (written by tools/release_apk.py).
  const versionLine = document.getElementById('version-line');
  if (versionLine && site.androidApk) {
    fetch('download/latest.json', { cache: 'no-store' })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((m) => {
        if (typeof m.versionName === 'string') {
          versionLine.textContent = `Version ${m.versionName} · for Android 7.0 and newer.`;
        }
      })
      .catch(() => {});
  }

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

  // The bar gets a background once the page scrolls.
  const nav = document.getElementById('nav');
  if (nav) {
    const onScroll = () => nav.classList.toggle('scrolled', window.scrollY > 8);
    window.addEventListener('scroll', onScroll, { passive: true });
    onScroll();
  }

  // Sections slide in as they scroll into view.
  const reveals = document.querySelectorAll('.reveal');
  if (reduced || !('IntersectionObserver' in window)) {
    reveals.forEach((el) => el.classList.add('in'));
  } else {
    const io = new IntersectionObserver(
      (entries) => {
        entries.forEach((e) => {
          if (!e.isIntersecting) return;
          // Siblings arrive one after another.
          const i = Array.prototype.indexOf.call(e.target.parentElement.children, e.target);
          setTimeout(() => e.target.classList.add('in'), Math.min(i, 6) * 80);
          io.unobserve(e.target);
        });
      },
      { rootMargin: '0px 0px -8% 0px', threshold: 0.12 },
    );
    reveals.forEach((el) => io.observe(el));
  }

  // What the server sees: noise that keeps changing.
  const noise = document.getElementById('noise');
  if (noise && !reduced) {
    const chars = 'ABCDEFGHJKMNPQRSTUVWXYZabcdefghijkmnpqrstuvwxyz23456789#$%&*+=?';
    setInterval(() => {
      let s = '';
      for (let i = 0; i < 6; i++) s += chars[Math.floor(Math.random() * chars.length)];
      noise.textContent = s + '…';
    }, 140);
  }

  // How much is tested, in one line.
  const stats = document.getElementById('stats-line');
  if (stats) {
    fetch('assets/report.json', { cache: 'no-store' })
      .then((r) => (r.ok ? r.json() : Promise.reject(new Error(String(r.status)))))
      .then((report) => {
        const suites = report.suites || [];
        const passed = suites.reduce((n, s) => n + (s.passed || 0), 0);
        const failed = suites.reduce((n, s) => n + (s.failed || 0), 0);
        if (passed > 0 && failed === 0) stats.textContent = `${passed} automated tests passing`;
      })
      .catch(() => {});
  }
})();
