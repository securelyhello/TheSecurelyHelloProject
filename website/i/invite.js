// Reads the invite token from /i/<token> (or ?t=<token>) and hands it to the
// app. The token stays in this page: nothing is fetched or logged.
(function () {
  const site = window.SITE || {};
  const valid = /^[A-Za-z0-9_-]{22}$/;
  const fromPath = location.pathname.split('/').filter(Boolean);
  let token = fromPath[0] === 'i' && fromPath[1] ? fromPath[1] : '';
  if (!valid.test(token)) token = new URLSearchParams(location.search).get('t') || '';
  if (!valid.test(token)) token = location.hash.slice(1);

  if (!valid.test(token)) {
    document.getElementById('invalid').hidden = false;
    return;
  }

  document.getElementById('valid').hidden = false;
  const appLink = 'securelyhello://invite/' + token;
  const webLink = location.origin + '/i/' + token;
  document.getElementById('open').href = appLink;
  document.getElementById('link').textContent = webLink;

  const copy = document.getElementById('copy');
  copy.addEventListener('click', () => {
    navigator.clipboard.writeText(webLink).then(
      () => { copy.textContent = 'Copied'; },
      () => { copy.textContent = 'Select the link above and copy it'; },
    );
  });

  document.querySelectorAll('[data-link]').forEach((a) => {
    const url = site[a.dataset.link];
    if (url) a.href = url;
    else a.hidden = true;
  });
})();
