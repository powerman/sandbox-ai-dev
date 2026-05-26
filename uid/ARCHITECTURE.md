# Separate-user Runtime Architecture

This document describes the runtime behaviour of the `uid/` prototype.
Installation and host preparation are covered in [README](README.md).
Linux and tool behaviour that is not specific to this implementation lives in
[../GOTCHAS.md](../GOTCHAS.md).

## Startup and SSH transport

`~/.local/bin/uid-ai-dev-startup`:

1. runs `uid-ai-dev-shutdown` best-effort;
2. syncs the sandbox config directory `~/.config/sandbox-ai-dev/`
   and the allowlisted host files from `~/.config/sandbox-ai-dev/sync-paths`;
3. syncs the staged home payload from `~/.local/share/sandbox-ai-dev/uid/sandbox-home/`;
4. starts the shared `ssh -nNT` ControlMaster in the background;
5. waits until `ssh -O check` succeeds on `$XDG_RUNTIME_DIR/uid-ai-dev-ssh`;
6. replaces itself with `uid-ai-dev uid-ai-dev-runsvdir-session`.

The split between the background master and the foreground session-holder is intentional.
The master owns the shared SSH transport for normal `ai-dev` clients,
but it does not need the environment-export logic provided by `uid-ai-dev` itself.
The foreground session-holder tracks the lifetime of `uid-ai-dev-runsvdir-session`.
When `uid-ai-dev-startup` exits for any reason,
the parent-death signal kills the background master too,
which disconnects every multiplexed `ai-dev` client.

## `uid-ai-dev` entry points

`~/.local/bin/uid-ai-dev` has two modes:

- `uid-ai-dev uid-ai-dev-runsvdir-session`
  - requires that the master is already reachable via `ssh -O check`;
  - opens a non-interactive `ssh -T` channel over that master;
  - runs the remote helper through the same environment export logic as normal clients;
- `uid-ai-dev [args...]`
  - requires that the master is already reachable via `ssh -O check`;
  - opens an interactive `-t` channel over the master;
  - fails closed instead of opening a standalone SSH session when the master is absent.

The explicit availability check is needed because `ControlPath` alone does not
force OpenSSH to use an already-running master;
see [../GOTCHAS.md](../GOTCHAS.md).

## Environment export contract

The launcher forwards a curated allowlist of host environment variables,
rewriting `/home/$HOST_USER` to `/home/$USER` inside forwarded values.
It also sets these fixed values inside `ai-dev`:

- `SSH_AUTH_SOCK=$HOME/.run/ssh-agent`
- `DBUS_SESSION_BUS_ADDRESS_HOST=unix:path=$HOME/.run/bus_host`
- `DOCKER_HOST=unix://$XDG_RUNTIME_DIR/docker.sock`
- `WAYLAND_DISPLAY=wayland-0`

For normal clients,
`DBUS_SESSION_BUS_ADDRESS` is read from the file written by the `dbus` service.
The session-holder path skips that step,
because it is responsible for bringing up the runit tree that later provides that file.

The staged `~/.local/bin/xdg-open` wrapper uses
`DBUS_SESSION_BUS_ADDRESS_HOST` for URL openings.
It re-execs `/usr/bin/xdg-open` under a tiny nested `bwrap` with `HOME=/home/$HOST_USER`
and a bind of the current `ai-dev` home onto that path,
so the browser-side caller path derives the same remote name as the host.
The staged `~/.local/bin/notify-send` wrapper uses the same filtered host bus
for notifications.

## Remote helper

`~/.local/bin/uid-ai-dev-runsvdir-session`:

- checks that `XDG_RUNTIME_DIR` exists;
- creates `~/.run/` and `~/.run/gnupg/`;
- applies ACLs so the host user can publish sockets there and `ai-dev` can use
  host-created sockets;
- ensures `~/.config/runsvdir/current`;
- exposes `wayland-0` and `pipewire-0` via symlinks under `XDG_RUNTIME_DIR`;
- if `~/.gnupg/` exists,
  kills any local `gpg-agent` started under `~/.gnupg/` and repoints the
  `gpgconf --list-dirs agent-socket` path at `~/.run/gnupg/S.gpg-agent`;
- `exec`s `runsvdir -P ...`.

`runsvdir -P` is still used so each `runsv` gets its own process group.
The SSH lifetime guarantee now comes from the split between the shared master
and the foreground session-holder,
not from shell-side cleanup or stdio detachment.

## Host-side helpers and shared socket layout

The main user's supervised helpers publish sockets into `~ai-dev/.run/`:

- `uid-ai-dev-ssh-agent-proxy` -> `/home/ai-dev/.run/ssh-agent`
- `uid-ai-dev-gpg-agent` keeps the real agent private at its host-side
  standard socket path
- `uid-ai-dev-gpg-agent-proxy` -> `/home/ai-dev/.run/gnupg/S.gpg-agent`
- `uid-ai-dev-xdg-dbus-proxy` -> `/home/ai-dev/.run/bus_host`
- `uid-ai-dev-wlproxy` -> `/home/ai-dev/.run/wayland-0`
- the main-user PipeWire/WirePlumber policy -> `/home/ai-dev/.run/pipewire-0`

`uid-ai-dev-ssh-agent` keeps the real agent private on the host at
`$XDG_RUNTIME_DIR/uid-ai-dev-ssh-agent`.
`ai-dev` clients in the sandbox always use the stable `~/.run/*` paths,
while private per-session runtime files continue to live in PAM's `/run/user/<uid>/`.

## Host-side same-cgroup mark policy

The external `ebpf-same-cgroup-mark` dependency attaches four cgroup hooks at
`/sys/fs/cgroup`:

- `same_cgroup_bind4`
- `same_cgroup_bind6`
- `same_cgroup_connect4`
- `same_cgroup_connect6`

The bind hooks store the creator cgroup ID in socket-local storage for TCP
listener sockets.
The connect hooks look up the destination listener,
compare its stored cgroup ID with the current task's cgroup,
and set `SO_MARK` on the client socket when they match.

The default mark bit is `0x40000000`.
An optional override can be configured through `ebpf-same-cgroup-mark`.

`/etc/nftables/uid-ai-dev.nft` accepts packets whose `socket mark` contains
`same_cgroup_mark` before the generic localhost/private-network rejects.
Unmarked traffic continues through the existing nftables policy unchanged.

## Shutdown

`~/.local/bin/uid-ai-dev-shutdown`:

1. Sends `ssh -O exit` to close the shared ControlMaster.
2. Falls back to a standalone SSH session to run `pkill -KILL -u $(id -u)` on `ai-dev`,
   terminating all remaining sandbox processes.

When the ControlMaster exits,
the `setpriv --pdeathsig=SIGHUP` set before starting it delivers SIGHUP to `uid-ai-dev-startup`,
which causes the foreground session-holder to exit.
The `pkill -KILL` handles any processes that persist after the SSH session ends.

## What lives where

Paths and resources used by the scripts.
Single source of truth for cross-references.

| Resource                           | Created by                          | Path / value                                                                      |
| ---------------------------------- | ----------------------------------- | --------------------------------------------------------------------------------- |
| SSH ControlMaster socket           | `uid-ai-dev-startup`                | `$XDG_RUNTIME_DIR/uid-ai-dev-ssh`                                                 |
| SSH agent (host-private)           | `uid-ai-dev-ssh-agent`              | `$XDG_RUNTIME_DIR/uid-ai-dev-ssh-agent`                                           |
| SSH agent socket (sandbox-visible) | `uid-ai-dev-ssh-agent-proxy`        | `/home/ai-dev/.run/ssh-agent`                                                     |
| GPG agent (host-private)           | `uid-ai-dev-gpg-agent`              | `gpgconf --list-dirs agent-socket` for `$HOME/.local/share/sandbox-ai-dev/.gnupg` |
| GPG agent socket (sandbox-visible) | `uid-ai-dev-gpg-agent-proxy`        | `/home/ai-dev/.run/gnupg/S.gpg-agent`                                             |
| Wayland proxy socket               | `uid-ai-dev-wlproxy`                | `/home/ai-dev/.run/wayland-0`                                                     |
| Host D-Bus proxy socket            | `uid-ai-dev-xdg-dbus-proxy`         | `/home/ai-dev/.run/bus_host`                                                      |
| PipeWire socket (sandbox-visible)  | PipeWire/WirePlumber host policy    | `/home/ai-dev/.run/pipewire-0`                                                    |
| Shared socket dir + ACLs           | `uid-ai-dev-runsvdir-session`       | `/home/ai-dev/.run/`                                                              |
| Session D-Bus socket               | `dbus` runit service                | `$XDG_RUNTIME_DIR/bus`                                                            |
| Session D-Bus address file         | `dbus` runit service                | `$XDG_RUNTIME_DIR/DBUS_SESSION_BUS_ADDRESS`                                       |
| Docker socket                      | `dockerd-rootless.sh` runit service | `$XDG_RUNTIME_DIR/docker.sock`                                                    |
| SSH keys for sandbox               | user (manual)                       | `$HOME/.local/share/sandbox-ai-dev/.ssh/`                                         |
| GPG keys for sandbox               | user (manual)                       | `$HOME/.local/share/sandbox-ai-dev/.gnupg/`                                       |
| Sandbox config                     | `uid-ai-dev-startup`                | `~/.config/sandbox-ai-dev/`                                                       |
| Config sync allowlist              | user (manual)                       | `~/.config/sandbox-ai-dev/sync-paths`                                             |
| Staged home payload                | user (manual)                       | `~/.local/share/sandbox-ai-dev/uid/sandbox-home/`                                 |

## Process trees

### Session holder and helpers

```text
Host user session ($USER):
uid-ai-dev-startup (runit service, long-lived session holder)
  ├─ [bg] ssh -nNT -o ControlMaster=yes     ← shared ControlMaster
  │         socket: $XDG_RUNTIME_DIR/uid-ai-dev-ssh
  │         setpriv --pdeathsig=SIGHUP: exits when startup exits
  └─ [fg] uid-ai-dev uid-ai-dev-runsvdir-session
               └─ ssh -T (over ControlMaster) → uid-ai-dev-runsvdir-session (as ai-dev)

Helper services (supervised separately, e.g. by $USER's runit):
uid-ai-dev-ssh-agent       ← ssh-agent for sandbox SSH keys
                             socket: $XDG_RUNTIME_DIR/uid-ai-dev-ssh-agent
uid-ai-dev-ssh-agent-proxy ← socat: uid-ai-dev-ssh-agent → /home/ai-dev/.run/ssh-agent
uid-ai-dev-gpg-agent       ← gpg-agent for sandbox GPG keys
uid-ai-dev-gpg-agent-proxy ← socat: (gpgconf socket) → /home/ai-dev/.run/gnupg/S.gpg-agent
uid-ai-dev-wlproxy         ← wlproxy → /home/ai-dev/.run/wayland-0
uid-ai-dev-xdg-dbus-proxy  ← xdg-dbus-proxy → /home/ai-dev/.run/bus_host
PipeWire/WirePlumber (host) ← host audio daemon, policy → /home/ai-dev/.run/pipewire-0
```

### Sandbox (ai-dev)

```text
PAM session (ai-dev, opened by sshd):
uid-ai-dev-runsvdir-session
  └─ runsvdir .config/runsvdir/current/
       ├─ dbus-daemon           ← session D-Bus (socket: $XDG_RUNTIME_DIR/bus)
       ├─ dockerd-rootless.sh   ← rootless Docker (socket: $XDG_RUNTIME_DIR/docker.sock)
       └─ gnome-keyring-daemon  ← secrets store (starts after D-Bus is ready)
```

### Per-command invocations

```text
uid-ai-dev [args…]
  └─ ssh -t (over ControlMaster) → user command (runs as ai-dev, in PAM session)
```

## URL opening and notifications

The staged home payload installs two wrappers that bridge sandbox apps to host services,
using `$DBUS_SESSION_BUS_ADDRESS_HOST` (the filtered host D-Bus proxy socket at
`$HOME/.run/bus_host`).

**`~/.local/bin/notify-send`:**
Sets `DBUS_SESSION_BUS_ADDRESS` to `$DBUS_SESSION_BUS_ADDRESS_HOST` and execs the system
`notify-send`. Desktop notifications from inside the sandbox reach the host notification daemon
via the `xdg-dbus-proxy` filter (which allows `org.freedesktop.Notifications`).

**`~/.local/bin/xdg-open`:**
For `http://`/`https://` URLs, runs the system `xdg-open` under a tiny nested `bwrap` that:

- sets `DBUS_SESSION_BUS_ADDRESS` to `$DBUS_SESSION_BUS_ADDRESS_HOST`;
- sets `HOME=/home/$HOST_USER`;
- bind-mounts the current `ai-dev` `$HOME` onto `/home/$HOST_USER`.

The `HOME` bind is needed so that the host browser resolves its profile directory
(`~/.mozilla`, `~/.config/chromium`, etc.) from the `ai-dev` home —
ensuring the browser opens with the correct profile and the same remote-name as the host user.

For non-HTTP URLs (file paths and other schemes), the system `xdg-open` is called directly
without the bwrap wrapper.
