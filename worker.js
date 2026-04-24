export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      let path = url.pathname;

      if (path.length > 1 && path.endsWith('/')) {
        path = path.slice(0, -1);
      }

      const scripts = {
        '/install': 'https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/install.sh',
        '/win':     'https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/install.ps1',
        '/update':     'https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/update.sh',
        '/update.ps1': 'https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/scripts/update.ps1',
      };

      const isBrowser = request.headers.get('accept')?.includes('text/html');

      // UI
      if (path === '/' && isBrowser) {
        return new Response(`<!DOCTYPE html>
<html><head><title>CodeRaft Installer</title></head>
<body style="font-family:monospace;background:#0f172a;color:#e2e8f0;padding:40px">
<h1>CodeRaft Platform</h1>

<p>Install:</p>
<pre>curl -fsSL https://install.coderaft.io/install | bash</pre>

<p>Windows:</p>
<pre>irm https://install.coderaft.io/win | iex</pre>

<h2>Update</h2>
<p>Linux/macOS:</p>
<pre>curl -fsSL https://install.coderaft.io/update | bash</pre>

<p>Windows:</p>
<pre>irm https://install.coderaft.io/update.ps1 | iex</pre>

</body></html>`, {
          headers: { 'content-type': 'text/html; charset=utf-8' }
        });
      }

      // CLI root → bash installer
      if (path === '/') {
        path = '/install';
      }

      const target = scripts[path];

      if (!target) {
        return new Response(
`CodeRaft Platform

Install (Linux/macOS):  curl -fsSL https://install.coderaft.io | bash
Install (Windows):      irm https://install.coderaft.io/win | iex

Update (Linux/macOS):   curl -fsSL https://install.coderaft.io/update | bash
Update (Windows):       irm https://install.coderaft.io/update.ps1 | iex
`,
          {
            status: 200,
            headers: { 'content-type': 'text/plain; charset=utf-8' }
          }
        );
      }

      const cache = caches.default;
      const cacheKey = new Request(request.url, request);

      let response = await cache.match(cacheKey);
      if (response) return response;

      const resp = await fetch(target, {
        headers: {
          'User-Agent': 'CodeRaft-Installer',
          'Accept': 'text/plain',
        },
      });

      if (!resp.ok) {
        return new Response(`Upstream error (${resp.status})\n`, { status: 502 });
      }

      response = new Response(resp.body, {
        status: 200,
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'cache-control': 'public, max-age=300, s-maxage=300',
        },
      });

      ctx.waitUntil(cache.put(cacheKey, response.clone()));

      return response;

    } catch (err) {
      return new Response(`Internal error: ${err.message}\n`, { status: 500 });
    }
  },
};
