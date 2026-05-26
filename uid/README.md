# uid — Separate-user sandbox

This implementation runs the sandbox under a dedicated system user (`ai-dev`).
Isolation relies on standard multi-user OS boundaries
(UID-based file permissions, session separation, process ownership)
plus firewall rules and access proxies to restrict what this user can reach.
A new session is opened via `ssh ai-dev@localhost`.

> [!TIP]
>
> Start here unless you specifically need the namespace-level isolation
> that [ns](../ns/README.md) provides.

> [!NOTE]
>
> `uid` is the default architecture of this project.
> It relies more on correct host configuration than `ns` does,
> but it is much easier to explain, audit, and adapt to different setups.
> It also has a security advantage over `ns`:
> the sandbox `$HOME` is owned by a separate user,
> so the primary user cannot `cd` into sandbox project directories at all
> (OS-enforced), eliminating the risk of accidental host-side execution.

## Requirements

- Linux (Wayland compositor required — X11 makes sandbox escape trivial).
- [ebpf-same-cgroup-mark](https://github.com/powerman/ebpf-same-cgroup-mark) —
  marks TCP sockets so nftables can distinguish sandbox internal traffic.
- [wlproxy](https://github.com/powerman/wlproxy) —
  Wayland protocol proxy for blocking dangerous compositor globals in the sandbox.
- PipeWire + WirePlumber (if you need restricted audio access).
- `UsePAM yes` in `sshd_config`
  (so SSH creates an elogind session and `XDG_RUNTIME_DIR` for `ai-dev`).

### Host hardening

These host-side settings close common information-leakage paths:

- Mount `/proc` with `hidepid=2` (`hidepid=invisible`).
- Set umask to 027 or 077 (`UMASK=027` in `/etc/login.defs`,
  plus shell profile files in `/etc` and `$HOME`).
- Restrict `/home/*`, `/mnt`, and sensitive parts of `/var/log/*`
  with `o-rwx`. Use `setfacl` to compensate where needed.

### Secrets

Skip SSH/GPG if you will not use SSH/GPG inside the sandbox.

- Create new SSH/GPG keys, API tokens, and other secrets for use in the sandbox
  with minimal permissions (e.g. SSH key is GitHub-only, GPG key is sign-only).
- Provide sandbox SSH keys via a dedicated `ssh-agent` running on the host.
- Provide sandbox GPG keys via a dedicated `gpg-agent` running on the host
  (only public keys live inside the sandbox `~/.gnupg/`).
- Keep sandbox secrets in a dedicated `gnome-keyring-daemon` inside the sandbox.
- Do not store unencrypted secrets in the sandbox `$HOME` files or environment variables:
  - Prefer tools that can read secrets via `secret-tool`.
  - For other tools, create wrappers in sandbox `~/.local/bin`
    that load secrets with `secret-tool` just before execution.

### Safety rules

- Do not copy directories from the sandbox user's `$HOME` to the host.
  - Outside the sandbox it is **UNSAFE** to `cd` into a sandbox project directory
    or run commands operating on such directory (e.g. `git -C /path/to/sandbox/proj push`).
    This is because they may contain hidden files that execute outside the sandbox
    (git hooks, `.mise.local.toml`, `.envrc`).
- Use `git fetch`/`pull` to retrieve changes from sandbox repos.
- To work on the same project both inside and outside the sandbox,
  maintain two separate clones.
- For single files, `scp` is mostly safe (avoid `.envrc` and similar).

## Install

### 1. Copy files

```bash
sudo install -d /etc/nftables/uid-ai-dev.user.d
sudo install -m 755 uid/nftables/uid-ai-dev.nft /etc/nftables/
sudo install -d /etc/dbus-1/system.d
sudo install -m 644 uid/dbus-1/system.d/uid-ai-dev.conf /etc/dbus-1/system.d/
mkdir -p ~/.config/sandbox-ai-dev
cp -r config/. ~/.config/sandbox-ai-dev/
mkdir -p ~/.local/bin
cp uid/bin/uid-ai-dev* ~/.local/bin/
mkdir -p ~/.local/share/sandbox-ai-dev/uid/sandbox-home
cp -r uid/sandbox-home/. ~/.local/share/sandbox-ai-dev/uid/sandbox-home/
```

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
install -m 644 uid/pipewire/.config/pipewire/pipewire.conf.d/sandbox-ai-dev.conf \
    ~/.config/pipewire/pipewire.conf.d/
install -m 644 uid/pipewire/.config/wireplumber/wireplumber.conf.d/sandbox-ai-dev.conf \
    ~/.config/wireplumber/wireplumber.conf.d/
install -m 644 uid/pipewire/.local/share/wireplumber/scripts/client/sandbox-ai-dev.lua \
    ~/.local/share/wireplumber/scripts/client/
```

Restart PipeWire and WirePlumber
(e.g. `gentoo-pipewire-launcher restart & disown`)
or log out and back in.

> [!NOTE]
> `~ai-dev/.run/` must exist before PipeWire can create `pipewire-0` there.
> If it does not exist yet, restart PipeWire again after the first
> successful `uid-ai-dev-startup`.

### 2. Configure host

#### nftables

Apply the firewall:

```bash
sudo /etc/nftables/uid-ai-dev.nft
```

Arrange for it to reload at boot.

To add custom rules, place `.nft` files in `/etc/nftables/uid-ai-dev.user.d/`
using chains `user_output_before`, `user_output_after`.
See `example.nft` in the source directory.

#### eBPF same-cgroup mark

```bash
sudo ebpf-same-cgroup-mark load
```

The nftables ruleset matches packets carrying the `same_cgroup_mark` socket mark.
Use the same bit value in both nftables and `ebpf-same-cgroup-mark`.
Arrange for the load command to re-run at boot.

#### Create the `ai-dev` user

Create a dedicated `ai-dev` user with its own primary group.
**Keep supplementary groups minimal.**
Do not add `ai-dev` to broad shared groups such as `users`, `docker`, `video`,
or similar unless a specific test proves they are required.

```bash
sudo useradd --create-home --user-group --shell "$SHELL" \
    --comment sandbox --groups cron ai-dev
sudo passwd ai-dev
```

Rootless Docker needs subordinate UID/GID ranges
(see [Docker docs](https://docs.docker.com/engine/security/rootless/#prerequisites));
most `useradd` implementations create these automatically.

#### Set up SSH access

```bash
sudo install -d -m 700 -o ai-dev -g ai-dev ~ai-dev/.ssh
sudo install -m 600 -o ai-dev -g ai-dev your-public-key.pub \
    ~ai-dev/.ssh/authorized_keys2
```

Ensure `/etc/ssh/sshd_config` has `UsePAM yes`, then restart sshd
(e.g. `sudo sv t ssh` on runit).

#### Environment note

Make sure the `ai-dev` user's `$SHELL -l` sets `PATH` to include
`~/.local/bin`.
One way to do this is to set PATH in `~/.profile` (works for `sh` and `zsh`)
plus, if `~/.bash_login` or `~/.bash_profile` exists,
start it with `source ~/.profile`.
You can either setup these files in `~ai-dev/` or sync such files from your `$HOME`.

#### GPG public keys (optional)

Import public keys that match the host-side private key material:

```bash
ssh ai-dev@localhost 'gpg --import' <your-public-key.asc
```

### 3. Start services

All project services are started at DE session login
and stopped at DE session logout.

**Run as user services (runit, systemd, etc.):**

- `~/.local/bin/uid-ai-dev-startup` — session holder.
  The script:
  1. runs `~/.local/bin/uid-ai-dev-shutdown` best-effort to clear stale state;
  2. syncs the sandbox config directory `~/.config/sandbox-ai-dev/`
     and the allowlisted host files from
     `~/.config/sandbox-ai-dev/sync-paths`;
  3. syncs the staged home payload from
     `~/.local/share/sandbox-ai-dev/uid/sandbox-home/`;
  4. starts the SSH transport used by the separate-user sandbox;
  5. keeps the foreground session-holder attached to
     `uid-ai-dev-runsvdir-session`.
     `uid-ai-dev-shutdown` runs automatically when this service stops
     (closes the SSH master and terminates `ai-dev` processes).
- `~/.local/bin/uid-ai-dev-ssh-agent` / `uid-ai-dev-ssh-agent-proxy`
  — skip if you do not need SSH inside the sandbox.
- `~/.local/bin/uid-ai-dev-gpg-agent` / `uid-ai-dev-gpg-agent-proxy`
  — skip if you do not need GPG inside the sandbox.
- `~/.local/bin/uid-ai-dev-xdg-dbus-proxy`
- `~/.local/bin/uid-ai-dev-wlproxy`

Example: [runit services](example/uid/host-services-runit)
(replace "plasmashell" with the name of your DE process if not using KDE Plasma).

## Usage

Run commands inside the sandbox:

```text
uid-ai-dev [command...]
```

Without arguments — opens an interactive shell.

The launcher requires the SSH transport started by `uid-ai-dev-startup`;
it fails closed otherwise.

> [!NOTE]
> To use Neovim inside the sandbox, run a terminal instead of Neovim directly.
> Neovim's LSP/MCP-server helper processes must survive Neovim exit
> and be shared between instances —
> this breaks if the sandbox kills child processes on exit.

> [!NOTE]
> The sandbox may need restarts to see host-side changes in synced files.
> With rsync-based sync, you can manually re-sync without restarting.
> TODO: Try bindfs and update accordingly.

The sandbox-home payload includes wrappers for `xdg-open` (URL opening)
and `notify-send` (desktop notifications) that route through the filtered
host session D-Bus proxy — see [ARCHITECTURE.md](ARCHITECTURE.md) for details.

## Further reading

- [ARCHITECTURE.md](ARCHITECTURE.md) — architecture, lifecycle, and services.
