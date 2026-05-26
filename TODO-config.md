# TODO: Move hardcoded values into config files

See AGENTS.md § Configuration Separation for the general rule.

## Definite

### runit vs systemd

The runsv service files under `uid/sandbox-home/.config/runsvdir/all/`
are tied to runit. A systemd-based install would need unit files instead.

### NVIDIA GPU devices

`ns/bin/ns-ai-dev-startup` — the block of `/dev/nvidia*` bind mounts
(lines 181–186).

If the target machine has no NVIDIA GPU and uses something else
(AMD, Intel, or only /dev/dri), these must be adjusted.
Should be driven by a config file (e.g. `config/gpu-devices`).

### SUBNET for veth pair

`ns/sbin/ns-ai-dev-init` — `SUBNET` read from `~/.config/sandbox-ai-dev/ns/host_ip` via `ns-ai-dev-startup`.

Collides with common LAN subnets.

### Paths to sudo helpers

Hardcoded `/usr/local/sbin/ns-ai-dev-*` in three scripts:

- `ns/bin/ns-ai-dev-startup` — `sudo /usr/local/sbin/ns-ai-dev-init`
  and `sudo /usr/local/sbin/ns-ai-dev-cleanup`
- `ns/bin/ns-ai-dev-shutdown` — `sudo /usr/local/sbin/ns-ai-dev-cleanup`
- `ns/bin/ns-ai-dev-docker` — `sudo /usr/local/sbin/ns-ai-dev-cgroup-enter`

Different distros may want these in `/usr/sbin/`, `/usr/libexec/`, etc.
Should be in `config/sandbox-paths`.

## Low priority / uncertain

### ROOTFIX_PATHS

`ns/bin/ns-ai-dev-startup` — `/etc/ssh/ssh_config.d` (line 233).

If a distro ships a different ssh config layout
(e.g. `/etc/ssh/ssh_config.d/` vs `/etc/ssh/sshd_config.d/`),
this needs changing. Low priority (rarely matters).

### cgroup path

`/sys/fs/cgroup/ns-ai-dev` hardcoded in:

- `ns/sbin/ns-ai-dev-init`
- `ns/sbin/ns-ai-dev-cleanup`
- `ns/sbin/ns-ai-dev-cgroup-enter`

Normally fixed, but worth noting for future flexibility.
Should be grouped with `config/sandbox-paths` if moved.

### Path to nftables rules

`ns/sbin/ns-ai-dev-init` — `RULES="/etc/nftables/ns-ai-dev.nft"` (line 16).

Standard enough, but if a distro uses a different location
for nftables snippets, this breaks. Group with paths above.

### VETH interface names

`ns/sbin/ns-ai-dev-init` and `ns/sbin/ns-ai-dev-cleanup` —
`VETH_HOST="ns-ai-dev"`, `VETH_NS="veth0"` (lines 14–15).

Unlikely to conflict, but technically environment-specific.

### Environment whitelist

Duplicated between `uid/bin/uid-ai-dev` and `ns/bin/ns-ai-dev`.

Both the list of variables to pass and the `pass()` logic
are nearly identical but maintained separately.
A shared config or sourcing pattern would reduce drift.

Uncertain because env vars are a security boundary —
changing the whitelist has security implications,
so making it user-tunable is questionable.

### Docker data root

`ns/bin/ns-ai-dev-docker` — `DOCKER_DATA="$XDG_DATA_HOME/docker"` (line 20).

On systems where disk layout is unusual, one might want a different path.
Very low probability, but follows the pattern.

### SSH key glob patterns

`uid/bin/uid-ai-dev-ssh-agent-proxy` and `ns/bin/ns-ai-dev-startup` —
`find ... -name 'id_*' -not -name '*.pub'` (or the `ssh-add` call).

If a user has keys with non-standard names, they won't be auto-loaded.
Low priority (unlikely need, easy workaround).

### PipeWire socket name on host

`ns/bin/ns-ai-dev-startup` —
`pipewire-sandbox-ai-dev` (line 212, bind mount).

The host-side restricted PipeWire socket name is currently
a project convention. If another service already uses that name,
it would conflict. Very unlikely.
