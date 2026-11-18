# Website

The product page (`index.html`), the invite landing page (`i/`), and the
privacy and terms pages. It's plain static files, with no build step needed
to serve them. The site requests nothing from other hosts: no fonts, CDNs or
analytics.

## Before you deploy

1. Fill in `config.js`: store links, desktop downloads, source, contact
   address. Empty entries hide their buttons.
2. Point the server's `INVITE_BASE_URL` at `https://<this site>/i/`.
3. Replace the bracketed placeholders in `docs/legal/*.md` (have a lawyer
   review them), then rebuild the legal pages:

   ```
   python3 tools/build_site.py
   ```

## Refreshing screenshots and test results

The screenshots are captured by the UI test against a real server, and
`assets/report.json` holds the latest test counts. With the dev server running
(see the main README, "Tests"):

```
MAIL_DIR=/tmp/sh_mail python3 tools/build_site.py --run-tests --with-integration
```

On a headless machine, add
`SITE_TEST_WRAPPER="xvfb-run -a dbus-run-session --"`. The script exits with
an error, and still writes the report, if any test fails.

## Serving

Serve this folder at the domain root. Two things matter:

- `/i/<token>` must serve `i/index.html`. The page reads the token from the
  path.
- Send security headers. The pages also carry a CSP meta tag, but
  `frame-ancestors` and HSTS only work as real headers.

Caddy:

```
securelyhello.example {
	root * /srv/securelyhello/website
	rewrite /i/* /i/index.html
	log_skip /i/*
	file_server
	header {
		Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'"
		Strict-Transport-Security "max-age=31536000; includeSubDomains"
		Referrer-Policy "no-referrer"
		X-Content-Type-Options "nosniff"
		Permissions-Policy "camera=(), microphone=(), geolocation=()"
	}
	@report path /assets/report.json
	header @report Cache-Control "no-cache"
}
```

nginx:

```
server {
    server_name securelyhello.example;
    root /srv/securelyhello/website;
    # Invite tokens are in these paths: keep them out of the logs.
    location /i/ { access_log off; try_files /i/index.html =404; }
    # expires, not add_header: add_header here would drop the headers below.
    location = /assets/report.json { expires -1; }
    add_header Content-Security-Policy "default-src 'self'; img-src 'self' data:; style-src 'self'; script-src 'self'; connect-src 'self'; base-uri 'none'; form-action 'none'; frame-ancestors 'none'" always;
    add_header Strict-Transport-Security "max-age=31536000; includeSubDomains" always;
    add_header Referrer-Policy "no-referrer" always;
    add_header X-Content-Type-Options "nosniff" always;
    add_header Permissions-Policy "camera=(), microphone=(), geolocation=()" always;
    # listen / ssl_certificate lines for your setup
}
```

Both configs keep `/i/` paths out of the access log, since they contain
invite tokens.
