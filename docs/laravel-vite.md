# Laravel + Vite behind vhosty

vhosty serves your Laravel app at `https://<folder>.<domain>` and your Vite dev
server at `https://<port>.<domain>`. Laravel and Vite each need a little setup to
generate correct HTTPS URLs. Everything here is opt-in through `.env`, so
teammates who don't use vhosty aren't affected.

## 1. Laravel: generate HTTPS URLs

In the project's `.env`:

```dotenv
APP_URL=https://escrow.vhosty.link
```

Then run `php artisan config:clear`.

When PHP runs through vhosty's PHP-FPM, Caddy tells PHP that the request is HTTPS,
so Laravel already generates `https://` links.

If you run `php artisan serve` and proxy it through a port subdomain instead
(`https://8000.<domain>`), trust the proxy so Laravel reads Caddy's
`X-Forwarded-*` headers. In `bootstrap/app.php`:

```php
->withMiddleware(function (Middleware $middleware) {
    $middleware->trustProxies(at: ['127.0.0.1', '::1']);
})
```

Only trust localhost, not `*`. In production, requests never come from
`127.0.0.1`, so this line has no effect there.

## 2. Vite: hot reload through the proxy

Install [vite-plugin-vhosty](https://github.com/zacksmash/vite-plugin-vhosty):

```bash
npm i -D vite-plugin-vhosty
```

```js
import vhosty from 'vite-plugin-vhosty';

export default defineConfig({
    plugins: [
        vhosty(), // must come before laravel()
        laravel({ input: ['resources/css/app.css', 'resources/js/app.js'], refresh: true }),
        vue(),
    ],
});
```

The plugin reads your domain from `~/.vhosty/config`, picks a free port, and serves
Vite at `https://<port>.<domain>` with hot reload. It needs no `.env` changes, and it does
nothing on machines without vhosty, so teammates aren't affected.

<details>
<summary>Without the plugin</summary>

Add these to your `.env` only. Don't commit them:

```dotenv
DEV_PROXY_HOST=5173.vhosty.link
DEV_VITE_PORT=5173
```

Avoid the `VITE_` prefix. Vite exposes `VITE_*` variables to the browser bundle.

In `vite.config.js`, use the proxy settings only when `DEV_PROXY_HOST` is set:

```js
import { defineConfig, loadEnv } from 'vite';
import laravel from 'laravel-vite-plugin';
import vue from '@vitejs/plugin-vue';

export default defineConfig(({ mode }) => {
    const env = loadEnv(mode, process.cwd(), '');
    const proxyHost = env.DEV_PROXY_HOST;

    return {
        plugins: [
            laravel({ input: ['resources/css/app.css', 'resources/js/app.js'], refresh: true }),
            vue(),
        ],
        server: proxyHost
            ? {
                  host: '127.0.0.1',
                  port: Number(env.DEV_VITE_PORT || 5173),
                  strictPort: true,
                  origin: `https://${proxyHost}`,
                  allowedHosts: [proxyHost],
                  cors: { origin: env.APP_URL },
                  hmr: { host: proxyHost, protocol: 'wss', clientPort: 443 },
              }
            : {
                  // your normal settings, unchanged
              },
    };
});
```

Use `env.APP_URL` from `loadEnv`, not `process.env.APP_URL`. `process.env` doesn't
include your `.env` file.

</details>

### Several projects at once

The plugin takes the next free port for each project (5173, 5174, and so on) and
prints the matching URL on startup. Without the plugin, give each project its own
`DEV_VITE_PORT` and `DEV_PROXY_HOST`.

### No hot reload needed?

Skip the dev server and run `npx vite build --watch`. Assets build into
`public/build`, Laravel serves them from the same domain, and you refresh by hand.
Delete `public/hot` if it exists.

## Troubleshooting

| Symptom | Cause |
|---|---|
| Mixed content warnings | `public/hot` still points at `http://...`. Check `cat public/hot`; it should say `https://<port>.<domain>`. |
| Assets load from `http://localhost:5173` | Vite started without `DEV_PROXY_HOST`. Check the `.env`, then restart `npm run dev`. |
| 502 on `https://5173.<domain>` | Vite isn't running, or it's on a different port. Run `lsof -nP -iTCP:5173 -sTCP:LISTEN`. |
| `EOF` in Caddy's log for the Vite host | Vite is serving HTTPS itself (`detectTls`, `basicSsl()`, `server.https`). Turn that off; Caddy handles HTTPS. |
| CORS errors along with 525 | The DNS record is proxied by Cloudflare (orange cloud). Run `vhosty dns sync`. |
| Fonts load from an old hostname | Laravel's Vite plugin caches font URLs in `public/fonts-manifest.dev.json`. Stop Vite, delete that file and `public/hot`, then start Vite again. Add both files to `.gitignore`. |
