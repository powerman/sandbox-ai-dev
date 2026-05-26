# ns — Namespace-based sandbox

This implementation uses Linux namespaces (`unshare`/`bwrap`)
to create isolated network, process, and filesystem contexts —
the same technology that powers Docker containers.
More of the isolation comes from namespace separation
than from host-side rules around a separate user account.

> [!TIP]
>
> Use `ns` when you need namespace-level isolation:
> private localhost, mount view, PID space, and network namespace semantics.

> [!WARNING]
>
> Currently relies on elogind; systemd support not yet implemented.

## Requirements

- Linux (Wayland compositor required — X11 makes sandbox escape trivial).
- [Bubblewrap](https://github.com/containers/bubblewrap).
- [wlproxy](https://github.com/powerman/wlproxy) —
  Wayland protocol proxy for blocking dangerous compositor globals in the sandbox.
- PipeWire + WirePlumber (if you need restricted audio access).

Docker inside the sandbox needs subuid/subgid
([/etc/subgid](#identity-mapping-host-groups-via-etcsubgid))
mapping to access host devices.

### Secrets

Skip SSH/GPG if you will not use SSH/GPG inside the sandbox.

- Create new SSH/GPG keys, API tokens, and other secrets for use in the sandbox
  with minimal permissions (e.g. SSH key is GitHub-only, GPG key is sign-only).
- Provide sandbox SSH keys via a dedicated `ssh-agent` running on the host.
- Provide sandbox GPG keys via a dedicated `gpg-agent` running on the host
  (only public keys live inside the sandbox `~/.gnupg/`).
- Keep sandbox secrets in a dedicated `gnome-keyring-daemon` inside the sandbox.
- Do not store unencrypted secrets in `$SANDBOX_HOME` files or environment variables:
  - Prefer tools that can read secrets via `secret-tool`.
  - For other tools, create wrappers in `$SANDBOX_HOME/.local/bin`
    that load secrets with `secret-tool` just before execution.

### Safety rules

- Place `$SANDBOX_HOME` outside your `$HOME` (e.g. `/home/yourname.ai-dev/`).
  - Subdirs in `$SANDBOX_HOME` follow the same layout as `$HOME`.
  - Alternatively, use `$HOME/.sandbox/ai-dev.<RANDOM>/` with `chmod 0100 $HOME/.sandbox`,
    though some tools may warn on failed `readdir(~/.sandbox)`.
- Do not copy directories from `$SANDBOX_HOME` to the host
  or access them directly from the host.
  - Outside the sandbox it is **UNSAFE** to `cd` into a sandbox project directory
    or run commands operating on such directory (e.g. `git -C /path/to/sandbox/proj push`).
    This is because they may contain hidden files that execute outside the sandbox
    (git hooks, `.mise.local.toml`, `.envrc`).
- Use `git fetch`/`pull` to retrieve changes from sandbox repos.
- To work on the same project both inside and outside the sandbox,
  maintain two separate clones.

## Install

### 1. Copy files

```bash
sudo cp ns/sbin/ns-ai-dev* /usr/local/sbin/
sudo install -d /etc/nftables/ns-ai-dev.user.d
sudo install -m 755 ns/nftables/ns-ai-dev.nft /etc/nftables/
mkdir -p ~/.config/sandbox-ai-dev
cp -r config/. ~/.config/sandbox-ai-dev/
mkdir -p ~/.local/bin
cp ns/bin/ns-ai-dev* ~/.local/bin/
```

Create `~/.config/sandbox-ai-dev/ns/host_ip` (see `host_ip.example`) —
pick a subnet that does not conflict with your LAN.

Optionally create `~/.config/sandbox-ai-dev/sync-paths` (see `sync-paths.example`) —
pick your config files to sync into the sandbox.

#### PipeWire / WirePlumber (audio restriction)

Skip this section if your host does not use PipeWire.

The sandbox uses a dedicated PipeWire socket and a WirePlumber Lua component
to allow audio playback while blocking microphone capture.

```bash
mkdir -p ~/.config/pipewire/pipewire.conf.d \
    ~/.config/wireplumber/wireplumber.conf.d \
    ~/.local/share/wireplumber/scripts/client
install -m 644 ns/pipewire/.config/pipewire/pipewire.conf.d/sandbox-ai-dev.conf \
    ~/.config/pipewire/pipewire.conf.d/
install -m 644 ns/pipewire/.config/wireplumber/wireplumber.conf.d/sandbox-ai-dev.conf \
    ~/.config/wireplumber/wireplumber.conf.d/
install -m 644 ns/pipewire/.local/share/wireplumber/scripts/client/sandbox-ai-dev.lua \
    ~/.local/share/wireplumber/scripts/client/
```

Restart PipeWire and WirePlumber
(e.g. `gentoo-pipewire-launcher restart & disown`)
or log out and back in.

### 2. Configure host

#### nftables

Apply the firewall:

```bash
sudo /etc/nftables/ns-ai-dev.nft
```

Arrange for it to reload at boot.

To add custom rules, place `.nft` files in `/etc/nftables/ns-ai-dev.user.d/`
using chains `user_input_before`, `user_input_after`, `user_forward_before`, `user_forward_after`.
See `example.nft` in the source directory.

#### Identity-mapping host groups via /etc/subgid

The sandbox uses subuid mapping (inner UID 0 → outer subuid start, e.g. 100000),
leaving host UID 0 and GIDs below 1000 unmapped inside the sandbox.
Files owned by privileged host groups (e.g. `/dev/dri/card*` by `root:video`)
become inaccessible (`nobody:nobody`).

To make a host group effective inside the sandbox,
identity-map its GID in `/etc/subgid`:

```text
yourname:100000:65536
yourname:27:1          # video — /dev/dri/card*, /dev/nvidiactl
yourname:28:1          # render — /dev/dri/renderD*
```

Multi-GID ranges work too (e.g. `yourname:27:2` is equivalent to the two lines above).

#### Configure privileged access

Add these to `/etc/sudoers` via `sudo visudo`:

```text
yourname ALL=(root) NOPASSWD: /usr/local/sbin/ns-ai-dev-init
yourname ALL=(root) NOPASSWD: /usr/local/sbin/ns-ai-dev-cgroup-enter
yourname ALL=(root) NOPASSWD: /usr/local/sbin/ns-ai-dev-cleanup
```

> [!NOTE]
> On systemd, `ns-ai-dev-cgroup-enter` can be replaced with
> `echo $$ >/sys/fs/cgroup/ns-ai-dev/cgroup.procs`
> (inside `ns-ai-dev-docker`), removing the need for one sudo entry.

### 3. Start services

All project services are started at DE session login
and stopped at DE session logout.

**Run directly via DE session hooks:**

- `~/.local/bin/ns-ai-dev-startup` — at DE session login.
  The script creates the sandbox:
  1. starts `gpg-agent`, `ssh-agent`, `wlproxy`, and `xdg-dbus-proxy` on the host;
  2. then creates the sandbox namespace (veth, firewall, cgroup).
- `~/.local/bin/ns-ai-dev-shutdown` — at DE session logout.

**Run as user services (runit, systemd, etc.):**

- `~/.local/bin/ns-ai-dev-system-dbus` — system D-Bus inside the sandbox.
- `~/.local/bin/ns-ai-dev-dbus` — session D-Bus inside the sandbox.
- `~/.local/bin/ns-ai-dev-docker` — Docker daemon inside the sandbox.

TODO: Run these services under `runsvdir` inside the sandbox —
similar to how the `uid` variant does it.

## Usage

Run commands inside the sandbox:

```text
ns-ai-dev <command> [args...]
```

> [!NOTE]
> To use Neovim inside the sandbox, run a terminal instead of Neovim directly.
> Neovim's LSP/MCP-server helper processes must survive Neovim exit
> and be shared between instances —
> this breaks if the sandbox kills child processes on exit.

> [!NOTE]
> The sandbox must be restarted to pick up host-side file changes
> in bind-mounted files. Prefer bind-mounting directories over individual files.

## Further reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — namespace topology, UID/GID maps,
  lifecycle, network stack, process trees.
