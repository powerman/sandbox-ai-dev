# Implementation-specific: namespace-based sandbox (ns)

Current implementation targets Linux systems without systemd
and relies on elogind.

Planned changes:

- Add ns/sandbox-home for running user services inside the sandbox,
  analogous to the uid variant.

## Installation

```text
config/*                         - to ~/.config/sandbox-ai-dev/
ns/nftables/ns-ai-dev.nft        - to /etc/nftables/ (loaded by ns-ai-dev-init)
ns/pipewire/.config/*            - to ~/.config/
ns/pipewire/.local/share/*       - to ~/.local/share/
ns/bin/ns-ai-dev                 - to ~/.local/bin/ (run a command inside the sandbox)
ns/bin/ns-ai-dev-startup         - to ~/.local/bin/ (start the sandbox)
ns/bin/ns-ai-dev-shutdown        - to ~/.local/bin/ (stop the sandbox)
ns/bin/ns-ai-dev-docker          - to ~/.local/bin/ (host user service: dockerd in sandbox)
ns/bin/ns-ai-dev-system-dbus     - to ~/.local/bin/ (host user service: system dbus in sandbox)
ns/bin/ns-ai-dev-dbus            - to ~/.local/bin/ (host user service: session dbus in sandbox)
ns/sbin/ns-ai-dev-init           - to /usr/local/sbin/ (sudo from ns-ai-dev-startup)
ns/sbin/ns-ai-dev-cleanup        - to /usr/local/sbin/ (sudo from ns-ai-dev-shutdown)
ns/sbin/ns-ai-dev-cgroup-enter   - to /usr/local/sbin/ (sudo from ns-ai-dev-docker)
```

## Entry points

- `ns-ai-dev` — Runs a given application inside the sandbox
  (a standalone app such as VS Code or Claude Code,
  or a terminal for manual work and running Neovim/VS Code/Claude Code).
  - Supports the `--sandbox-no-dbus` flag required by `ns-ai-dev-dbus`.
- `ns-ai-dev-docker` — Starts a rootful `dockerd` inside the sandbox.
  Only sandbox files (not host files) are accessible to containers and their bind-mounts.
  Root inside a container = sandbox user namespace root = UID 100000 on the host.
- `ns-ai-dev-system-dbus` — Starts a system `dbus-daemon` inside the sandbox.
  D-Bus-activated services inherit the sandbox mount namespace
  and cannot access host files.
- `ns-ai-dev-dbus` — Starts a session `dbus-daemon` inside the sandbox.
  D-Bus-activated services inherit the sandbox mount namespace
  and cannot access host files.

## Exit points

- `ns-ai-dev-startup` — Starts:
  - `gpg-agent` on the host, whose socket is accessible inside the sandbox.
  - `ssh-agent` on the host, whose socket is accessible inside the sandbox.
  - `xdg-dbus-proxy` on the host,
    proxying some services from the host session D-Bus into the sandbox.
  - `wlproxy` on the host, filtering dangerous Wayland interfaces
    (clipboard without focus, overlay attacks, screen capture, input injection).
  - `ns-ai-dev-init`, which adds a veth interface and firewall rules
    for the sandbox on the host.
- Bind-mounted into the sandbox via bwrap:
  - Devices in `/dev` and `/sys`.
  - The host's restricted PipeWire socket
    `$XDG_RUNTIME_DIR/pipewire-sandbox-ai-dev`,
    mounted inside the sandbox as `$XDG_RUNTIME_DIR/pipewire-0`.
  - The Wayland proxy socket
    `$XDG_RUNTIME_DIR/ns-ai-dev/$WAYLAND_DISPLAY` (wlproxy).
  - Via `--bind`: the directories
    `$SANDBOX_HOME` and `$XDG_RUNTIME_DIR/ns-ai-dev`.
- Additional groups granted via `/etc/subgid` may give access to:
  - Devices in `/dev`.
  - Host sockets in `/run`.
  - Directories and files in `/etc` mounted via `--ro-bind`.

## Sync points

- On sandbox startup (e.g. when the DE session starts), these run in parallel:
  - `ns-ai-dev-startup`
  - User services (via runsv):
    - `ns-ai-dev-docker`
    - `ns-ai-dev-system-dbus`
    - `ns-ai-dev-dbus`
- The `ns-ai-dev-startup` script:
  - Creates the namespace for the sandbox.
  - Configures the veth, firewall, and cgroup for that namespace
    (via `ns-ai-dev-init`).
  - Starts `gpg-agent`, `ssh-agent`, and `xdg-dbus-proxy` for the sandbox.
  - Writes sandbox environment variables to a temporary directory,
    then atomically renames it to `$XDG_RUNTIME_DIR/ns-ai-dev/env/` when done.
- User services check for the existence of `env/` on startup:
  if the directory has not yet been created, they exit with code 1,
  and the supervisor (e.g. runit) restarts them after ~1 second.
- The `ns-ai-dev-dbus` script, after `env/` appears, opens the file
  `env/DBUS_SESSION_BUS_ADDRESS` for writing and starts `dbus-daemon`,
  which writes its address with GUID there on startup.
- The `ns-ai-dev` script waits for `env/` to appear (startup completion),
  and — unless `--sandbox-no-dbus` is passed — also waits for
  `env/DBUS_SESSION_BUS_ADDRESS` to be non-empty.
- On shutdown (e.g. when the DE session ends),
  `ns-ai-dev-shutdown` runs:
  - Stops `gpg-agent`, `ssh-agent`, and `xdg-dbus-proxy`.
  - Removes the namespace/veth/firewall/cgroup (via `ns-ai-dev-cleanup`).
  - Removes `$XDG_RUNTIME_DIR/ns-ai-dev/` (including `env/`).
