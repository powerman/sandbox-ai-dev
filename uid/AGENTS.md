# Implementation-specific: separate-user sandbox (uid)

## Installation

```text
config/*                            - to ~/.config/sandbox-ai-dev/
uid/dbus-1/system.d/uid-ai-dev.conf - to /etc/dbus-1/system.d/
uid/nftables/uid-ai-dev.nft         - to /etc/nftables/
uid/pipewire/.config/*              - to ~/.config/
uid/pipewire/.local/share/*         - to ~/.local/share/
uid/sandbox-home/*                  - to ~/.local/share/sandbox-ai-dev/uid/sandbox-home/
uid/bin/uid-ai-dev                  - to ~/.local/bin/ (run a command inside the sandbox)
uid/bin/uid-ai-dev-startup          - to ~/.local/bin/ (start the sandbox)
uid/bin/uid-ai-dev-shutdown         - to ~/.local/bin/ (stop the sandbox)
uid/bin/uid-ai-dev-xdg-dbus-proxy   - to ~/.local/bin/ (host user service: xdg-dbus-proxy)
uid/bin/uid-ai-dev-wlproxy          - to ~/.local/bin/ (host user service: wlproxy)
uid/bin/uid-ai-dev-ssh-agent        - to ~/.local/bin/ (host user service: ssh-agent)
uid/bin/uid-ai-dev-ssh-agent-proxy  - to ~/.local/bin/ (host user service: socat)
uid/bin/uid-ai-dev-gpg-agent        - to ~/.local/bin/ (host user service: gpg-agent)
uid/bin/uid-ai-dev-gpg-agent-proxy  - to ~/.local/bin/ (host user service: socat)
```

## Entry points

- `uid-ai-dev` — Runs a command inside the sandbox as user `ai-dev`
  via `ssh` over the already-established shared ControlMaster.
  If run without arguments — opens an interactive shell.

## Exit points

- `uid-ai-dev-startup` — Performs a best-effort shutdown,
  syncs the config allowlist and staged sandbox-home,
  starts the shared `ssh -nNT` ControlMaster,
  and `exec`s `uid-ai-dev uid-ai-dev-runsvdir-session`.
- `uid-ai-dev-shutdown` — Closes the shared SSH master
  and remotely terminates the `ai-dev` user's processes.
- Services running on the host:
  - `uid-ai-dev-ssh-agent` — dedicated ssh-agent with sandbox SSH keys.
  - `uid-ai-dev-ssh-agent-proxy` — publishes the ssh-agent socket
    at `/home/ai-dev/.run/ssh-agent`.
  - `uid-ai-dev-gpg-agent` — dedicated gpg-agent with sandbox GPG keys.
  - `uid-ai-dev-gpg-agent-proxy` — publishes the GnuPG socket
    at `/home/ai-dev/.run/gnupg/S.gpg-agent`.
  - `uid-ai-dev-wlproxy` — publishes the filtered Wayland socket
    at `/home/ai-dev/.run/wayland-0`.
  - `uid-ai-dev-xdg-dbus-proxy` — publishes the host session D-Bus proxy
    at `/home/ai-dev/.run/bus_host`.
- Inside the sandbox, `uid-ai-dev-runsvdir-session`:
  - creates `~/.run` and `~/.run/gnupg`;
  - configures ACLs for host helper sockets;
  - exposes `wayland-0` and `pipewire-0` via symlinks in `XDG_RUNTIME_DIR`;
  - starts `runsvdir`.
