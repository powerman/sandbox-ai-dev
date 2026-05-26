# TODO: URL-opening mitigation via sandboxed browser

## Problem

When an app inside the sandbox opens a URL via `xdg-open`,
the URL is forwarded to the host browser through D-Bus (`xdg-dbus-proxy`).
The host browser opens and executes the page's JavaScript
in the host network context — **outside** the sandbox network namespace.

That JavaScript can:

- Probe `localhost` ports on the host via timing side-channels (`fetch()` with `mode: 'no-cors'`).
- Send state-changing requests (`POST`/`PUT`/`DELETE`) to services on `localhost` or LAN
  that lack CSRF protection (admin panels, CouchDB, Elasticsearch, router UIs, etc.).

The sandbox firewall blocks direct connections from the sandbox to `localhost`/LAN,
but it cannot intercept requests made by the host browser on behalf of a page
opened from the sandbox.

## Proposed mitigation

Extend the existing `xdg-open` wrapper (already in `$SANDBOX_HOME/.local/bin/xdg-open`)
to route URLs differently based on their destination:

- **localhost / LAN URLs** → open in a browser running **inside the sandbox**,
  which is subject to the sandbox network namespace (firewall blocks LAN/localhost access).
- **External URLs** → continue to forward to the host browser as now.

The JavaScript of a locally-served page opened in the sandbox browser
will be restricted by the sandbox firewall and cannot reach host `localhost`
or the LAN from the browser process.

## Implementation plan

### 1. Decide on the in-sandbox browser

Firefox is the most practical choice:

- Natively supports Wayland (`MOZ_ENABLE_WAYLAND=1`).
- The sandbox already provides access to `$WAYLAND_DISPLAY`.
- Already installed (used by the current xdg-open path for external URLs).
- Supports `--profile <dir>` to use an isolated profile directory,
  preventing profile lock conflicts with the host Firefox instance.

Create a dedicated Firefox profile directory in `$SANDBOX_HOME`:

```sh
mkdir -p "$HOME/.mozilla/sandbox"
```

This profile is separate from the host profile (`~/.mozilla/firefox/`),
so both Firefox instances can run simultaneously without lock conflicts.

> **Note**: The sandbox already bind-mounts `~/.mozilla/firefox/profiles.ini` read-only
> for the current external-Firefox path.
> With a sandbox-local profile this mount becomes unnecessary for the new path —
> evaluate whether it can be removed to reduce the attack surface.

### 2. Implement the URL-routing logic in xdg-open

The wrapper should classify URLs and dispatch accordingly.
Create or update `$SANDBOX_HOME/.local/bin/xdg-open`:

```bash
#!/bin/bash
# xdg-open: route localhost/LAN URLs to the sandbox browser,
# external URLs to the host browser via D-Bus proxy.
set -euo pipefail

url="${1:-}"

is_local_url() {
    # IPv4 loopback and private ranges, IPv6 loopback and ULA.
    # Also match bare hostnames without dots (e.g. "mydevserver").
    local host
    host=$(printf '%s' "$url" | sed -n 's|^https\?://\([^/:@]*\).*|\1|p')
    [[ -z $host ]] && return 1
    case "$host" in
        localhost | \
        127.*)                       return 0 ;;  # IPv4 loopback
        10.*)                        return 0 ;;  # RFC1918
        192.168.*)                   return 0 ;;  # RFC1918
        172.1[6-9].* | 172.2[0-9].* | 172.3[01].*) return 0 ;;  # RFC1918
        \[::1\] | ::1)               return 0 ;;  # IPv6 loopback
        \[fd*\] | \[fc*\])           return 0 ;;  # IPv6 ULA
        *.*) return 1 ;;                           # FQDN — treat as external
        *)   return 0 ;;                           # bare hostname — treat as local
    esac
}

if [[ "$url" == http://* || "$url" == https://* ]] && is_local_url; then
    # Open in sandbox browser (runs in sandbox netns — cannot reach host localhost).
    exec firefox --profile "$HOME/.mozilla/sandbox" --new-instance "$url"
fi

# Fall through: non-URL args and external URLs go to the host browser.
DBUS_SESSION_BUS_ADDRESS="$DBUS_SESSION_BUS_ADDRESS_HOST" \
    exec /usr/bin/xdg-open "$@"
```

> **Important**: The `DBUS_SESSION_BUS_ADDRESS_HOST` env var is already set
> by `ns-ai-dev` from `env/DBUS_SESSION_BUS_ADDRESS_HOST`.
> The wrapper relies on it being available in the environment.

### 3. Handle Firefox startup latency

The first `firefox --new-instance` invocation takes several seconds to start.
Subsequent invocations within the same session will reuse the running instance
(Firefox checks for a running instance even with `--new-instance`
for the same profile in the same D-Bus session).

If Firefox is not installed in the sandbox, consider alternatives:

- `chromium --user-data-dir="$HOME/.config/chromium-sandbox" "$url"` — also Wayland-native.
- `epiphany` (GNOME Web) — lightweight, Wayland-native.

The wrapper should try the available browser and fall back gracefully.
Consider making the browser name configurable via an env var
or a config file in `$SANDBOX_HOME`.

### 4. Remaining attack vector

Even with this wrapper, a malicious app can bypass `xdg-open` entirely
and call D-Bus directly using `DBUS_SESSION_BUS_ADDRESS_HOST`.
The currently allowed D-Bus calls include:

```
org.mozilla.firefox.OpenURL @ /org/mozilla/firefox/Remote
```

This allows passing any URL directly to the host Firefox, bypassing the wrapper.

To close this remaining vector, remove `org.mozilla.firefox.*` from the
`xdg-dbus-proxy` allowlist in `bin/ns-ai-dev-startup`.
This means all URL opening will go through the wrapper → sandbox browser.
The user will lose the ability to "open in host Firefox" from inside the sandbox —
evaluate whether this trade-off is acceptable.

If external URLs should still open in the host browser via D-Bus,
one option is an intermediary D-Bus service on the host that acts as a
`org.mozilla.firefox`-compatible endpoint but filters URLs before forwarding.
This is significantly more complex to implement.

### 5. Test

- Open a URL to `http://localhost:8080` from inside the sandbox (e.g. via `xdg-open`).
  Verify it opens in a browser running inside the sandbox (check the process namespace).
- Open an external URL (e.g. `https://example.com`).
  Verify it opens in the host browser.
- Verify that a page opened at `http://localhost:8080` inside the sandbox
  cannot `fetch()` other localhost ports on the host.
  (The sandbox browser is in the sandbox netns; `localhost` inside it
  is the sandbox's loopback, not the host's.)

## Caveats and risks

- A malicious app bypassing `xdg-open` via direct D-Bus calls
  can still reach the host browser (see step 4 above).
  The wrapper is a best-effort mitigation, not a complete fix.
- The sandbox browser shares the Wayland socket with the host compositor.
  Any Wayland-level vulnerabilities (clipboard, layer-shell) still apply
  to the sandbox browser.
- The regex for local URL detection must be kept up to date.
  IPv6 address formats are particularly tricky (`[::1]`, `::1`, `[::ffff:127.0.0.1]`).
  Consider using a more robust parser (e.g. `python3 -c "import urllib.parse…"`).
