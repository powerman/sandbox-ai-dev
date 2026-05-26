# Sandbox Architecture: Namespaces and Cgroups

This document describes how Linux namespaces and cgroups are composed to build the sandbox.

For Linux/kernel/tooling behaviour referenced here
(why `--map-root-user` is avoided, why mounts lock across userns, etc.),
see [GOTCHAS](../GOTCHAS.md).

## Namespace layout

Two long-lived holder pipelines carry the namespaces shared by every sandbox invocation:

| Holder | Created in                                               | Owns                              | Used by                        |
| ------ | -------------------------------------------------------- | --------------------------------- | ------------------------------ |
| **U1** | `unshare --user --setuid 0 -- bwrap --unshare-pid`       | user, pid, bwrap-modified mount   | bwrap monitor, bwrap reaper    |
| **U2** | `unshare --user --uts --ipc --net -- {rootfix} -- sleep` | user (child of U1), uts, ipc, net | terminals, IDEs, D-Bus daemons |

The sandbox's PID namespace is created by **bwrap** (`--unshare-pid`),
not by the surrounding `unshare` — so PID 1 of the sandbox is the bwrap
init reaper running inside bwrap's modified mount ns; the bwrap inner
(the user command — an `unshare --user` that exec-chains into `sleep infinity`)
ends up as PID 2 in U2's userns.
This makes `/proc/1/root` (and every other `/proc/<pid>/root` for sandbox processes)
point at the bwrap layout rather than the raw host layout —
host-FS leaks via that magic symlink are structurally impossible.
The bwrap monitor lives in the host PID namespace,
so it is not visible from inside the sandbox.

Host-side scripts can still kill / nsenter into the holders even though
those run as inner UID 0 (host subuid 100000): from `init_user_ns`,
`cap_capable` walks one userns level down and grants the cap via
`uid_eq(ns->owner, cred->euid)`. That owner-UID override fires _one_
level down, **not** at the same level — which is also why a user inside
the sandbox cannot use the same shortcut to ptrace inner-UID-0 holders
even though their inner UID 1000 maps back to host UID 1000 that owns U1.
See GOTCHAS § "/proc/<pid>/root bypasses caller's mount ns" for the kernel mechanism.

Both holders are created **once** at session startup and live for the whole session.
Every per-invocation `ns-ai-dev` call enters U2's user/pid/ipc/uts/mount/net via
`nsenter --target $U2_TARGET_PID …`, instead of running its own bwrap.
This guarantees a single, consistent filesystem view across all sandbox processes.

Docker mode additionally creates dockerd-private mount + pid namespaces inside U2.
The private pid ns is required so that containers launched with `docker run --pid=host`
can mount procfs — see § "Cgroup setup" → "Why dockerd needs its own pid ns".

### Why two userns layers

Sandbox apps must not be able to remount bwrap's `--ro-bind` mounts read-write.
The primary protection is the capability check on `mount()` remount:
`CAP_SYS_ADMIN` is required in the userns that owns the mount ns (U1),
and sandbox apps in U2 have no caps in U1.
An additional `lock_mnt_tree` layer activates when a sandbox app
creates a new mount ns — the `copy_mnt_ns()` crosses the U1→U2 boundary
and sets `MNT_LOCK_READONLY` on the copied ro-binds
(see GOTCHAS § "Protection of bwrap --ro-bind mounts").

If sandbox apps lived directly in U1 (which owns bwrap's mount ns),
they would have `CAP_SYS_ADMIN` in the mount-ns owner userns
and could remount anything.
Putting them in U2 (a child of U1) blocks remounts via the capability check alone.

U2 also owns its own netns (created with `unshare --user --net`),
which satisfies `net_current_may_mount`'s requirement that dockerd have `CAP_SYS_ADMIN`
in the netns owner's userns to mount sysfs for `--privileged` containers
(see GOTCHAS § "net_current_may_mount").
dockerd runs directly in U2 and therefore owns the netns it operates in.

UTS and IPC namespaces are also created in U2 rather than U1.
U1 enables both protection layers: the capability check on remounts in its mount ns,
and the userns boundary that triggers `lock_mnt_tree` on copies of that mount ns.
The capability check is the primary mechanism; `lock_mnt_tree` is a consequence
of the two-userns design, not a separate design goal.

### Why bwrap reuses U1 instead of nesting

`unshare --setuid 0 --setgid 0` before `bwrap` makes bwrap's `is_privileged`
check see UID 0, so bwrap skips creating its own user namespace and reuses U1
(see GOTCHAS § "bwrap skips its own userns when caller is UID 0").
With identity sub-id mapping, inner UID 0 has no real-host privileges —
outer UID 0 is unmapped, so inner UID 0 appears as overflow UID 65534
for root-owned host files.

Single shutdown kill target:
`U1_KILL_PID` is the bwrap init reaper (PID 1 in the sandbox pid ns).
SIGKILL on it destroys the sandbox pid ns,
which the kernel cascades into a SIGKILL of every other process in that pid ns
(terminals, dbus, dockerd, U2 sleep).
The bwrap monitor's `wait()` then returns and monitor exits — releasing U1's user namespace.

## UID/GID mapping

### U1

Written by `newuidmap` / `newgidmap` via
`--map-users auto`, an explicit `--map-groups` set built from `/etc/subgid`,
and `--map-current-user`. Concrete shape (from `/proc/<u1-pid>/uid_map`):

```text
Inside U1              Disk (host)
──────────────────     ───────────────────────
0–999 (root + sys)    ←   100000–100999 (start of subuid range)
1000 (user)           ←   1000 (identity)
1001+                 ←   101000+ (rest of subuid range)

Outer UID 0 (real root)  →  unmapped → overflow UID 65534 inside U1
```

Identity-mapping host system groups (e.g. `video`=27, `render`=28)
keeps bind-mounted device files (`/dev/dri/card*`, `/dev/nvidiactl`) accessible.
The largest `/etc/subgid` entry becomes the fill range mapped to inner GIDs 0..N
(like `--map-groups auto`); other entries are identity-mapped.
See [README](../README.md) for the `/etc/subgid` setup.

### U2

Identity to U1 (column 2 rewritten in U1's userns so `U2 inner X = U1 inner X`,
see GOTCHAS § "Writing uid_map / gid_map").

```text
Inside U2             Inside U1 (parent)        Disk (host)
─────────────────     ──────────────────────    ─────────────────────
0–999 (root + sys)   ←   0–999 (subuid root)   ←   100000–100999
1000 (user)          ←   1000 (user)           ←   1000
1001+                ←   1001+                 ←   101000+
```

The container userns map is inherited from U2 verbatim
(no containerd auto-shift under identity);
see GOTCHAS § "Container UID mapping under non-init dockerd" for the general kernel behaviour.

Empirical map from `docker run --rm alpine cat /proc/self/uid_map`,
matching `/proc/$(pidof dockerd)/uid_map`:

```text
1000  1000      1
   0     0   1000
1001  1001  64535
```

So inside an alpine container:

- `id` reports `uid=0(root)`.
- `/etc/hosts` (created by dockerd as host UID 100000) appears owned by `uid 0`,
  matching the natural expectation.
- Files mounted from `~/...` (host UID 1000) appear owned by `uid 1000`.

**Historical note.**
Older revisions of this project (and other rootful-in-non-init-userns setups)
have reported a _shift_:
container UID 0 mapped to dockerd's UID 1000, not 0,
producing `bin`-owned bwrap dirs and similar oddities.
That symptom was tied to the older "rotate" mapping in dockerd's userns
and is not present under identity. If a future change
re-introduces a non-identity map there, re-check the container map;
containerd may apply additional adjustments.

dockerd at U2 UID 0 is **not** the file owner
(host UID 100000 is a subuid).
It accesses user (UID 1000) files via `CAP_DAC_OVERRIDE` in U2.

UX consequences of identity mapping:

- Sandbox-internal directories (created by bwrap as U1 inner UID 0 = host 100000)
  appear inside containers as `root` (U2 inner 0).
- `docker run --user=1000` containers see UID 1000 as the file owner
  (host UID 1000) → writes to bind-mounted user files succeed via plain DAC,
  matching host rootful docker behaviour.

### Security goal

Sandbox root (inner UID 0) maps to outer UID 100000, **not** real root.
With identity mapping (inner 0 = outer 0) anyone on the host could
`nsenter --user` into the sandbox and edit root-owned files without a password;
mapping to a subuid removes that path.

`--map-root-user` is avoided because it forces `setgroups=deny`
(see GOTCHAS § "setgroups=deny trap"),
which would later break `nsenter --user` against U1 / U2.

## What lives where

Names and paths used by the scripts. Single source of truth for cross-references.

| Resource                         | Created by               | Path / value                                                            |
| -------------------------------- | ------------------------ | ----------------------------------------------------------------------- |
| Sandbox external data (host)     | startup (`mkdir -p`)     | `~/.local/share/sandbox-ai-dev/` (not available inside bwrap)           |
| Sandbox home (host)              | user                     | `$HOME.ai-dev/` → bind to `$HOME` inside bwrap                          |
| Sandbox runtime dir (host)       | startup                  | `$XDG_RUNTIME_DIR/ns-ai-dev/` → bind to `$XDG_RUNTIME_DIR` inside bwrap |
| Session bus socket               | `ns-ai-dev-dbus`         | `$XDG_RUNTIME_DIR/ns-ai-dev/bus`                                        |
| Session bus address (with GUID)  | `ns-ai-dev-dbus`         | `$XDG_RUNTIME_DIR/ns-ai-dev/env/DBUS_SESSION_BUS_ADDRESS`               |
| System bus socket                | `ns-ai-dev-system-dbus`  | `$XDG_RUNTIME_DIR/ns-ai-dev/system_bus_socket`                          |
| Host-bus proxy socket (filtered) | startup (xdg-dbus-proxy) | `$XDG_RUNTIME_DIR/ns-ai-dev/bus_host`                                   |
| Wayland proxy socket (filtered)  | startup (wlproxy)        | `$XDG_RUNTIME_DIR/ns-ai-dev/$WAYLAND_DISPLAY`                           |
| Docker socket                    | `ns-ai-dev-docker`       | `$XDG_RUNTIME_DIR/ns-ai-dev/docker.sock`                                |
| Docker data root (inside bwrap)  | `ns-ai-dev-docker`       | `$HOME/.local/share/docker/`                                            |
| Delegated cgroup subtree         | `ns-ai-dev-init`         | `/sys/fs/cgroup/ns-ai-dev`                                              |
| Sandbox netns name               | `ns-ai-dev-init`         | `ns-ai-dev` (`/run/netns/ns-ai-dev`)                                    |
| Host-side veth                   | `ns-ai-dev-init`         | `ns-ai-dev` @ `192.168.x.1/30`                                          |
| U2-side veth                     | `ns-ai-dev-init`         | `veth0` @ `192.168.x.2/30`                                              |
| nftables table                   | `ns-ai-dev-init`         | `inet ns-ai-dev` (rules in `/etc/nftables/ns-ai-dev.nft`)               |

Key variables written by `ns-ai-dev-startup` to `$XDG_RUNTIME_DIR/ns-ai-dev/env/`
and read by other scripts from those files (not via inherited environment):

| File name                       | Purpose                                                                                  |
| ------------------------------- | ---------------------------------------------------------------------------------------- |
| `U1_KILL_PID`                   | bwrap init reaper (PID 1 in sandbox pid ns), in U1; SIGKILL target — cascades to all     |
| `U2_TARGET_PID`                 | U2's sleep (PID 2 in sandbox pid ns); nsenter target for U2's user/pid/ipc/uts/mount/net |
| `DBUS_SESSION_BUS_ADDRESS`      | Address of the in-bwrap session bus (written by `ns-ai-dev-dbus`)                        |
| `DBUS_SESSION_BUS_ADDRESS_HOST` | Address of the filtered host bus proxy                                                   |
| `SSH_AUTH_SOCK`                 | ssh-agent socket on host (bind-mounted into bwrap)                                       |
| `SSH_AGENT_PID`                 | ssh-agent PID, used by `ns-ai-dev-shutdown`                                              |

## Network stack

```text
host eth*
   │
   ├─ host route table, nftables (host-defined)
   │
   └─ veth host side: ns-ai-dev (192.168.x.1/30)
            │
            │  nftables `inet ns-ai-dev` (whitelist):
            │    block out 25/465/587 (SMTP)
            │    block out 80/443 to RFC1918 / link-local / loopback
            │    allow ICMP, DNS, SSH, HTTP/S, QUIC, UDP traceroute
            │    default deny
            │
            ▼
       U2 netns (owned by U2 userns):
            ├─ veth0 (192.168.x.2/30, default route via .1)
            ├─ docker0 + per-container veths (managed by dockerd)
            └─ lo
```

The terminal and dockerd share U2's netns (both enter U2 via nsenter),
so `curl http://localhost:8080` from the terminal reaches a `docker run -p 8080:80 …` container,
and `--network=host` containers see the same view as the terminal.

## Lifecycle

### Phase 1 — session startup

`bin/ns-ai-dev-startup` runs as the calling user at session start
(configured via the user's session startup mechanism, e.g. a runit service or autostart entry).
It can also be run standalone to restart the sandbox.

1. **Create the U1 + U2 holders** (single chain:
   outer unshare creates U1 and exec-chains into bwrap,
   bwrap layers the modified mount ns + sandbox pid ns on top,
   the bwrap-inner shell does rootfix and exec-chains into
   an inner `unshare --user` that creates U2):

   ```text
   unshare --user \
       --map-users auto --map-groups … --map-current-user \
       --setuid 0 --setgid 0 -- \
       bwrap --unshare-pid [binds, dirs, symlinks, chmods] -- \
       /bin/sh -c '
           # rootfix: cp /etc/ssh/ssh_config.d → /tmp/root/… + mount --bind
           exec unshare --user --uts --ipc --net -- sleep infinity   # creates U2
       '
   ```

   `--setuid 0 --setgid 0` is what gets bwrap to skip its own user namespace and reuse U1;
   see § "Why bwrap reuses U1 instead of nesting".
   No `--pid`, `--mount-proc`, `--mount-binfmt` on the outer `unshare`:
   the sandbox PID namespace is created by bwrap below, not here.
   No `--fork`/`--kill-child`: unshare exec-chains directly into bwrap monitor,
   so there is no intermediate process.
   The bwrap monitor stays in the host PID namespace,
   so it is invisible from inside the sandbox.

   The inner shell wrapper also performs the **rootfix** pass:
   for each entry in `ROOTFIX_PATHS` (currently `/etc/ssh/ssh_config.d`),
   copy the host path into a tmpfs staging dir as inner UID 0
   and bind-mount the copy over the original
   (GOTCHAS § "Outer UID 0 is unmapped → overflow UID").
   Without this, host-root-owned files appear inside the sandbox as the overflow UID,
   and tools like `ssh` refuse to load them.
   Add entries to `ROOTFIX_PATHS` in `bin/ns-ai-dev-startup` as new tools require them.

   The trailing `exec unshare --user --uts --ipc --net -- sleep infinity` creates U2
   with its own uts, ipc, and net namespaces.
   The rootfix runs in U1 (full caps, can write `/etc/ssh/`-style paths in
   the bwrap layout); the userns boundary is moved to _just before_ the sleep
   so that U2 contains every long-lived sandbox process
   and every per-invocation nsenter target —
   this places sandbox processes outside the mount-ns owner userns (U1),
   blocking remounts via the capability check;
   a later `unshare(CLONE_NEWNS)` from U2 additionally triggers
   `lock_mnt_tree` on the copied bwrap mounts
   (see GOTCHAS § "Protection of bwrap --ro-bind mounts").

   Then writes U2's `uid_map` / `gid_map` from inside U1's userns
   (`nsenter --target $U1_MONITOR_PID --user`, where `$U1_MONITOR_PID` is the
   bwrap monitor process — in U1), single-write, identity-rewritten
   (see GOTCHAS § "Writing uid_map / gid_map").
   The target sleep's PID is `pgrep`'d from the bwrap reaper.

   Saves bwrap's host-side reaper PID to `U1_KILL_PID` (shutdown SIGKILL target)
   and the U2 sleep host PID to `U2_TARGET_PID` (per-invocation nsenter target).
   U2's host-level PID is passed directly to `ns-ai-dev-init` (which runs on the host).

User-side host services (`gpg-agent`, `ssh-agent`, `xdg-dbus-proxy`, `wlproxy`) are started
before step 1 — they are independent of namespace setup.
Their sockets are bind-mounted into bwrap via the bwrap holder arguments.

Four further user services are designed for a process supervisor (e.g. runit)
and are not started by the startup script:

| Service                 | Where it runs        | Purpose                                 |
| ----------------------- | -------------------- | --------------------------------------- |
| `ns-ai-dev-docker`      | inside the U2 holder | rootful dockerd, listens on docker.sock |
| `ns-ai-dev-system-dbus` | inside the U2 holder | isolated system bus for sandbox         |
| `ns-ai-dev-dbus`        | inside the U2 holder | session bus for sandbox                 |

### Phase 2 — privileged init

`sbin/ns-ai-dev-init` runs as real root via `sudo` from the startup script.
Takes U2's host PID as argument.

1. **Network.**
   Bind-mounts `/proc/$U2_HOST_PID/ns/net` to `/run/netns/ns-ai-dev`
   (see GOTCHAS § "ip netns and bind-mounting netns files"),
   creates the host↔U2 veth pair, configures addresses/routes,
   loads nftables rules on the host side.

2. **Cgroup delegation.**
   Creates `/sys/fs/cgroup/ns-ai-dev`,
   chowns `.`, `cgroup.procs`, `cgroup.subtree_control`, `cgroup.threads`
   to the calling user.
   See GOTCHAS § "cgroup v2 delegation" for why a fixed delegated subtree
   is used instead of the caller's session cgroup.

### Phase 3 — running sandboxed apps

`bin/ns-ai-dev` runs as the calling user (no sudo),
uses a single `nsenter`, drops privileges, then chdirs to `$HOME`:

```text
env -i [whitelisted vars] \
    nsenter --target $U2_TARGET_PID --user --pid --ipc --uts --mount --net -- \
    setpriv --reuid=$UID --regid=$GID --init-groups --pdeathsig SIGTERM -- \
    /bin/sh -c 'cd "$HOME"; exec "$@"' -- "$@"
```

The nsenter pulls in U2's user namespace, sandbox pid/ipc/uts,
the bwrap-modified mount layout, and U2's own netns
(because `U2_TARGET_PID` is U2's sleep inside bwrap's mount ns).

The chdir to `$HOME` is done by `/bin/sh` **after** all namespace switches.
`nsenter --wd=PATH` is unsuitable:
it resolves `PATH` in the caller's mount ns _before_ `setns(CLONE_NEWNS)`,
so the resulting cwd dentry can point at a host inode invisible inside the
bwrap layout (see GOTCHAS § "nsenter --wd=PATH resolves path before setns").
The shell wrapper avoids this by running `cd "$HOME"` after namespace switches.

**Docker mode (`bin/ns-ai-dev-docker`).** Same single nsenter, then
`unshare --mount --pid --fork --mount-proc` creates dockerd's private mount + pid namespaces —
required for `--pid=host` containers
(see § "Cgroup setup" → "Why dockerd needs its own pid ns").
Container cgroups are placed inside the delegated subtree via `--cgroup-parent`
(see § "Cgroup setup" → "Why --cgroup-parent instead of cgroup namespace").

## Cgroup setup

```text
/sys/fs/cgroup/ns-ai-dev          ← created and chowned by ns-ai-dev-init
└── docker/                            ← --cgroup-parent ns-ai-dev/docker
    └── (container cgroups managed by dockerd)
```

Before starting dockerd, `bin/ns-ai-dev-docker` moves itself into the
delegated subtree via the sudo helper `sbin/ns-ai-dev-cgroup-enter`.
Dockerd uses `--cgroup-parent ns-ai-dev/docker`
so that container cgroups are created inside the delegated subtree
(the only subtree with write access from inside the sandbox).

### Why --cgroup-parent instead of cgroup namespace

A per-invocation cgroup namespace (`unshare --cgroup`) would make the delegated
subtree appear as `/` in `/proc/self/cgroup` and in cgroup2 mounts.
It was removed because:

- The sandbox does not isolate cgroup visibility between processes
  (terminal and `--privileged` containers share the same actor),
  so hiding the host cgroup tree in docker but not in the terminal
  provides no actual isolation.
- The per-invocation `unshare --cgroup --mount` required a nested bash
  and a second `setpriv` layer to handle pdeathsig,
  adding complexity for no security benefit.
- `--cgroup-parent` achieves the same functional result
  (container cgroups inside the delegated subtree)
  without namespace manipulation.

### Why dockerd needs its own mount + pid ns

dockerd is wrapped in `unshare --mount --pid --fork --mount-proc` even though
the threat model treats every actor in U2 (terminal, dbus, dockerd) as
equivalent and would not require this for isolation.
Both namespaces are required:

- **pid ns** — required by the kernel for `docker run --pid=host` containers:
  Mounting procfs requires `CAP_SYS_ADMIN` in the userns that owns the target
  pid ns (see GOTCHAS § "mount procfs requires CAP_SYS_ADMIN in pid-ns owner
  userns"). bwrap's pid ns is owned by U1, so containers in U2 cannot mount
  procfs there; `unshare --pid --fork` from a U2-resident task creates a pid ns
  owned by U2, making the procfs mount possible.
  Containers without `--pid=host` work either way:
  they create their own pid ns via `CLONE_NEWPID` from dockerd in U2, owned by U2.

- **mount ns** — required by overlay2 storage driver:
  - Without a private mount ns, `mount -t overlay` fails with `EPERM`
    because the shared mount ns is owned by U1,
    and dockerd in U2 has no `CAP_SYS_ADMIN` there.
  - The `--mount` flag (required by `--mount-proc`) also confines dockerd's
    overlay mounts to its own mount ns rather than leaking into the holder's.

`tini -s` is needed because dockerd becomes PID 1 in this private pid ns:
PID 1 must reap orphaned zombies (containerd-shim children get reparented onto PID 1)
and forward signals to its child for graceful shutdown.
dockerd does neither robustly when run as PID 1.

`--mount` (paired with `--pid --mount-proc`) is required by `--mount-proc`,
which mounts a fresh procfs over `/proc`;
this also confines dockerd's overlay mounts to its own mount ns rather than leaking into U2.

## Process trees

### Holders

```text
U1 + U2 holder (single chain, host pid ns at the top):
unshare --user --setuid 0 →exec→ bwrap --unshare-pid  ← monitor ($U1_MONITOR_PID):
                                                                              host pid ns, in U1,
                                                                              caller's mount ns,
                                                                              inner UID 0
      └─ bwrap (init reaper)     ← PID 1 in sandbox pid ns ($U1_KILL_PID),
                                   in U1, in bwrap's modified mount ns, inner UID 0;
                                   shutdown SIGKILL target — its death destroys
                                   the sandbox pid ns
            └─ unshare --user --uts --ipc --net (exec'd from /bin/sh after rootfix)
                  └─ sleep infinity   ← PID 2 in sandbox pid ns ($U2_TARGET_PID);
                                        in U2 userns + U2 uts/ipc/net, in bwrap's mount ns;
                                        per-invocation nsenter target
                                        (PID is preserved through both execve's;
                                        unshare → exec sleep, no extra fork)
```

### Normal mode (terminal / IDE / agent)

```text
nsenter --target $U2_TARGET_PID --user --pid --ipc --uts --mount --net
  └─ setpriv --reuid=1000 --regid=1000 --init-groups
        └─ /bin/sh -c 'cd "$HOME"; exec …'   ← chdir after mount-ns switch
              └─ user app    ← e.g. terminal, shell, IDE,
                               claude-code, run as UID 1000
```

### Docker mode

```text
nsenter --target $U2_TARGET_PID --user --pid --ipc --uts --mount --net
  └─ setpriv --pdeathsig SIGKILL  ← SIGKILL on parent death (unshare can't ignore SIGKILL)
        └─ unshare --mount --pid --fork --mount-proc --kill-child=SIGTERM
              └─ tini -s          ← SIGTERM on unshare death (via --kill-child's internal pdeathsig)
                    └─ dockerd     ← graceful shutdown via tini signal forwarding
                                     U2 UID 0 (= host 100000), in U2's netns, own mount/pid ns
```

The private pid ns is required for `docker run --pid=host` containers
(see § "Cgroup setup" → "Why dockerd needs its own pid ns");
it is **not** there for isolation from terminals
(no isolation requirement under the project's threat model).

The terminal and dockerd share U2's netns
(`curl http://localhost:8080` from the terminal reaches `docker run -p 8080:80 …`,
`--network=host` containers see the same view as the terminal).

### D-Bus session / system

```text
nsenter --target $U2_TARGET_PID --user --pid --ipc --uts --mount --net
  └─ setpriv --reuid=1000 --regid=1000 --init-groups
        └─ dbus-daemon          ← session or system bus
              └─ (on-demand)    ← gcr-prompter, xdg-desktop-portal, etc.
```
