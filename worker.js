export default {
  async fetch(request, env, ctx) {
    try {
      const url = new URL(request.url);
      let path = url.pathname;

      if (path.length > 1 && path.endsWith('/')) {
        path = path.slice(0, -1);
      }

      const scripts = {
        // Unified platform installer (dashboard deploys products)
        '/':          { url: 'https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/install.sh', type: 'bash' },
        '/win':       { url: 'https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/install.ps1', type: 'ps1' },

        // Legacy per-product installers (still work, redirect to unified)
        '/entraguard':     { url: 'https://raw.githubusercontent.com/LiamJ74/entra-audit-installer/master/install.sh', type: 'bash' },
        '/entraguard.ps1': { url: 'https://raw.githubusercontent.com/LiamJ74/entra-audit-installer/master/install.ps1', type: 'ps1' },
        '/ravenscan':      { url: 'https://raw.githubusercontent.com/LiamJ74/ravenscan-installer/master/install.sh', type: 'bash' },
        '/ravenscan.ps1':  { url: 'https://raw.githubusercontent.com/LiamJ74/ravenscan-installer/master/install.ps1', type: 'ps1' },
        '/redfox':         { url: 'https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/install.sh', type: 'bash' },
        '/redfox.ps1':     { url: 'https://raw.githubusercontent.com/LiamJ74/coderaft-installer/master/install.ps1', type: 'ps1' },

        // Aliases
        '/entra-audit':    { url: 'https://raw.githubusercontent.com/LiamJ74/entra-audit-installer/master/install.sh', type: 'bash' },
        '/secaudit':       { url: 'https://raw.githubusercontent.com/LiamJ74/ravenscan-installer/master/install.sh', type: 'bash' },
      };

      // Help page for browsers
      if (path === '/' && request.headers.get('user-agent')?.includes('Mozilla')) {
        return new Response(
`<!DOCTYPE html>
<html><head><title>CodeRaft Installer</title>
<style>body{font-family:monospace;max-width:600px;margin:40px auto;padding:20px;background:#0f172a;color:#e2e8f0}
h1{color:#38bdf8}code{background:#1e293b;padding:2px 8px;border-radius:4px;color:#34d399}
.section{margin:24px 0}a{color:#38bdf8}</style></head>
<body>
<h1>CodeRaft Platform</h1>
<p>Security. Identity. Access. Unified.</p>
<div class="section">
<h2>Install (Linux / macOS)</h2>
<code>curl -fsSL https://install.coderaft.io | bash</code>
</div>
<div class="section">
<h2>Install (Windows / PowerShell)</h2>
<code>irm https://install.coderaft.io/win | iex</code>
</div>
<div class="section">
<p>The installer deploys the CodeRaft Dashboard.<br>
Activate your license in the dashboard to deploy your products.</p>
<p><a href="https://coderaft.io">coderaft.io</a> &middot; <a href="mailto:contact@coderaft.io">contact@coderaft.io</a></p>
</div>
</body></html>`,
          { headers: { 'content-type': 'text/html; charset=utf-8' } }
        );
      }

      // CLI help for root path
      if (path === '/help') {
        return new Response(
`CodeRaft Installer

Platform (recommended):
  curl -fsSL https://install.coderaft.io | bash
  irm https://install.coderaft.io/win | iex

Individual products (legacy):
  curl -fsSL https://install.coderaft.io/entraguard | bash
  curl -fsSL https://install.coderaft.io/ravenscan | bash

  irm https://install.coderaft.io/entraguard.ps1 | iex
  irm https://install.coderaft.io/ravenscan.ps1 | iex
`,
          { headers: { 'content-type': 'text/plain; charset=utf-8' } }
        );
      }

      const target = scripts[path];
      if (!target) {
        return new Response(`Unknown path: ${path}\nTry: curl -fsSL https://install.coderaft.io | bash\n`, {
          status: 404,
          headers: { 'content-type': 'text/plain; charset=utf-8' },
        });
      }

      // Serve script with caching
      const cache = caches.default;
      const cacheKey = new Request(request.url, request);
      let response = await cache.match(cacheKey);
      if (response) return response;

      const resp = await fetch(target.url, {
        headers: { 'User-Agent': 'CodeRaft-Installer', 'Accept': 'text/plain' },
      });

      if (!resp.ok) {
        return new Response(`Failed to fetch installer (${resp.status}).\n`, { status: 502 });
      }

      response = new Response(resp.body, {
        status: 200,
        headers: {
          'content-type': 'text/plain; charset=utf-8',
          'cache-control': 'public, max-age=300',
        },
      });

      ctx.waitUntil(cache.put(cacheKey, response.clone()));
      return response;

    } catch (err) {
      return new Response(`Internal error: ${err.message}\n`, { status: 500 });
    }
  },
};
