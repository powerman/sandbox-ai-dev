# Linux Namespaces & Tooling Gotchas

This document collects non-obvious behaviour of the Linux kernel
(namespaces, capabilities, mount locking)
and of the userspace tools the project uses
(`unshare`, `nsenter`, `bwrap`, `setpriv`, `ssh`, `bash`, `dbus-daemon`,
`ip netns`, `tini`).

Everything here is general Linux knowledge that constrains the project's design.
The ARCHITECTURE files ([uid](uid/ARCHITECTURE.md), [ns](ns/ARCHITECTURE.md)) and the scripts
may reference these entries to justify a particular ordering, flag, or layout choice —
the rationale lives here, not in the code.

## User namespaces

### Mapping flags and the `setgroups=deny` trap

`unshare --map-root-user`
maps inner UID 0 to the calling user
and as a side effect writes `deny` to `/proc/<pid>/setgroups`,
because the mapping is performed without root privileges in the parent namespace.
Once written, `setgroups=deny` cannot be undone for that userns
and breaks every later `nsenter --user` against it,
because `util-linux nsenter` calls `setgroups(0, NULL)` after entering a userns
and aborts with `setgroups failed: Operation not permitted`.

`unshare --map-users auto / --map-groups … / --map-current-user`
delegates the mapping to the SUID helpers `newuidmap` / `newgidmap`,
which write the map without setting `setgroups=deny`.
This is the only way to combine "no real-root in the parent ns" with
"future `nsenter --user` still works".

### Writing `uid_map` / `gid_map` from a parent userns

A process inside the parent userns
(after `nsenter --target $PARENT --user`)
has `CAP_SETUID` / `CAP_SETGID` over the descendant
via `set_cred_user_ns`.
This lets it write a full multi-line map directly to `/proc/$CHILD/uid_map`
without first writing `deny` to setgroups.

Two non-obvious requirements:

1. **Single `write(2)`.**
   The kernel only accepts the first line if the map is written in multiple syscalls.
   Do **not** use bash `printf '%s\n' "$var"` — bash splits `write(2)` at embedded newlines
   in the argument, so any multi-line map fails with `EINVAL` on the second call.
   Use `awk '{…}' src > /proc/$PID/uid_map` or `cat tempfile > /proc/$PID/uid_map`.

2. **Column 2 is in the _immediate_ parent userns, not the host.**
   `/proc/self/uid_map` from inside U1 has column 2 in U1's parent (the host),
   so a naive copy of `/proc/self/uid_map` to `/proc/$U2/uid_map`
   silently produces a map in the wrong UID space.
   Symptom: later `setgid()` inside U2 fails with `EINVAL`.
   Fix: rewrite column 2 to equal column 1 (`awk '{print $1, $1, $3}'`)
   when you want identity mapping (U2 inner X = U1 inner X).

### Capabilities cross-userns

Per `user_namespaces(7)`:

> a process can exercise a capability ... if the capability is for a resource
> (e.g., file) whose UID and GID have a mapping inside the user namespace.

Practical consequences:

- A process with full caps inside U2 can use `CAP_DAC_OVERRIDE`
  to bypass DAC on host files
  **if** the host UID/GID of the file owner is mapped in U2.
- A process inside a parent userns
  has `CAP_SYS_ADMIN` over every descendant userns and
  every namespace owned by a descendant.
  So `nsenter --target $CHILD --net` from a process in the parent userns
  succeeds via `setns(CLONE_NEWNET)`,
  even though the caller is not in the child userns itself.

### `setns(CLONE_NEWUSER)` resets effective credentials

When a process enters a user namespace via `setns(CLONE_NEWUSER)`,
the kernel sets its credentials to inner UID 0 of the new namespace
regardless of the caller's outer UID
(`set_cred_user_ns` grants the full capability set inside the new userns).

`util-linux nsenter` then drops the effective UID to inner 0 deliberately,
which has two effects on this project:

- `bwrap`'s `is_privileged` check
  (defined as `real_uid == 0`) sees 0
  and skips creating its own child user namespace.
- With subuid mapping the outer UID is the subuid start (e.g. 100000), not real root,
  so this "privileged" path has no special host privileges.

### `commit_creds` resets `prctl(PR_SET_PDEATHSIG)`

`setns(CLONE_NEWUSER)` calls `commit_creds()`,
which resets `pdeath_signal` to 0
whenever the process gains new capabilities
(`!cred_cap_issubset(old, new)` is true on userns entry).

Therefore `setpriv --pdeathsig SIGKILL`
must be invoked **after** `nsenter --user`, not before.
A `--pdeathsig` set earlier is silently discarded.

### Outer UID 0 is unmapped → overflow UID

Without an explicit mapping for outer UID 0,
host-root-owned files
(e.g. `/etc/ssh/ssh_config.d/*`)
appear inside the sandbox as overflow UID 65534 (`nobody`).
Tools like SSH refuse to load files that are not owned by inner root or the caller.

Workaround: copy the file/directory to a writable tmpfs as inner UID 0
(so it ends up owned by inner root)
and bind-mount the copy over the original.

## `unshare` and `nsenter`

### `unshare --pid` affects children only

`unshare --pid` itself stays in the old PID namespace;
only the child process forked with `--fork` becomes PID 1 in the new namespace.
Saving the unshare PID for `nsenter --target` is wrong —
`nsenter --pid` must target a process that is **inside** the new PID ns.

`tini -s` is the natural choice for PID 1 in shared PID namespaces:
it reaps zombies (D-Bus-activated services routinely fork and orphan),
which `sleep infinity` cannot do.

### Saving PIDs across PID namespaces

A child PID is reported differently depending on which PID namespace observes it.
After `nsenter --target $U1_PID --user --pid --mount …`
the calling process's `/proc` view comes from U1's PID namespace,
so a PID seen there is "U1-relative".

To bridge between observers, read `/proc/<host-pid>/status`:
`NSpid: <host-pid> <U1-pid>` lists the PID at every nesting level.

`ns-ai-dev-init` receives the U2 sleep's **host-level** PID directly
(it acts on the host's `/proc`); no sandbox-PID-ns view is needed.

### `--mount-proc` / `--mount-binfmt`

`--mount-proc` (implies `--mount`)
creates a fresh mount namespace and mounts `/proc` inside it
so that `/proc` reflects the new PID namespace.
Without it, the new PID namespace's processes are running
but `/proc` is still the host's,
and `bwrap`'s parent fails to read `/proc/<child_pid>/ns/*` after `clone()`.

`--mount-binfmt` mounts `binfmt_misc` inside the same mount namespace,
isolating the sandbox from any host-registered binary handlers.

### `--kill-child` and `PR_SET_PDEATHSIG`

`unshare --kill-child` arranges for the kernel to deliver `SIGKILL` (or another signal)
to the forked child if `unshare` itself dies,
via `PR_SET_PDEATHSIG`.
Without it, a crashed `unshare` leaves an orphaned PID 1 in the new namespace
and any pidfile pointing at it goes stale.

### Capabilities are preserved between back-to-back `nsenter`s

Two nsenter calls in sequence
(e.g. `nsenter --target U1 --user --mount … nsenter --target U2 --net …`)
do not lose capabilities
provided the kuid stays the same:
`setns` is a single capability check
and there is no `exec` in between to drop them.

### `nsenter --wd=PATH` resolves path before `setns`

`nsenter --wd=PATH` resolves the given path in the caller's mount namespace
_before_ `setns(CLONE_NEWNS)` switches to the target mount namespace.
If the path does not exist in the caller's mount ns (or resolves to a different
inode there), the resulting cwd dentry points at an inode invisible in the
target mount ns, and `getcwd()` in the launched process then fails.

Workaround: perform `cd "$HOME"` (or equivalent) in a shell after
the namespace switch, so the path resolves inside the target mount ns.

## Mount namespaces, `lock_mnt_tree`, and sysfs

### Protection of bwrap `--ro-bind` mounts

Bwrap's `--ro-bind` mounts are protected from `remount,rw` primarily by
the capability check on `mount()` remount:
`CAP_SYS_ADMIN` is required in the user namespace that owns the mount ns.
The mount ns is owned by U1; sandbox processes (in U2) have all caps in U2
but none in U1, so every remount attempt in the shared mount ns
fails with `EPERM` —
even `remount,ro` is blocked,
because the capability check applies regardless of the remount flags.

An additional `lock_mnt_tree` layer activates when a sandbox process
creates a new mount ns (`unshare --mount`, docker's `unshare --mount`):
`copy_mnt_ns()` crosses the U1→U2 userns boundary
(the mount ns is owned by U1, the new process is in U2),
and `lock_mnt_tree()` sets `MNT_LOCKED`
(and `MNT_LOCK_READONLY` on read-only binds) on every mount in the copy.
`MNT_LOCK_READONLY` blocks `remount,rw` but allows `remount,ro`.
This layer is a consequence of the two-userns design,
not a separate design goal — it activates automatically
because the `unshare --user` that creates U2 is already present.

The two layers differ in observable behaviour:
without `unshare --mount`, the cap check blocks even `remount,ro`;
with `unshare --mount`, `MNT_LOCK_READONLY` allows `remount,ro` but blocks `remount,rw`.

Note: U2 itself does **not** create a new mount ns
(`--user --uts --ipc --net`, no `--mount`),
so `lock_mnt_tree` is **not** triggered at U2 creation time.
It fires on the first `copy_mnt_ns()` that crosses the U1→U2 boundary,
which is the first `unshare(CLONE_NEWNS)` from inside U2.

### `mnt_already_visible()` and `--privileged` sysfs mount

`mount -t sysfs` from inside a `--privileged` container
calls `mnt_already_visible()`,
which checks for `MNT_LOCKED` children covering non-empty directories under `/sys`.
If any such child exists, the mount is rejected with `EPERM` —
which incidentally blocks the standard `--privileged` sysfs escape vector.

The check uses `is_empty_dir_inode()` (`fs/libfs.c`),
which accepts only directories that use `empty_dir_inode_operations`.
sysfs directories do **not** use those operations,
so they always count as non-empty for this test.

### bwrap tmpfs overlays on `/sys/*` break sysfs visibility

`--tmpfs /sys/firmware`, `--tmpfs /sys/kernel`, etc.
create non-empty MNT_LOCKED children on top of the sysfs subtree.
`mnt_already_visible()` then rejects `mount -t sysfs` inside containers,
breaking dockerd container creation entirely.

**Use `--bind /sys` (rw) or `--ro-bind /sys` without per-subdir tmpfs overlays.**
`--ro-bind /sys` additionally blocks the `--privileged` (see above).

### cgroup2 mount placement vs MNT_LOCKED

Previous implementation mounted `cgroup2` inside a per-invocation mount namespace
layered by `unshare --cgroup --mount` before starting dockerd.
This is no longer done — dockerd now uses `--cgroup-parent`
to place container cgroups inside the delegated subtree,
and no per-invocation cgroup namespace or cgroup2 mount is created.

The `MNT_LOCKED` interaction described below is preserved for reference
in case cgroup namespace isolation is re-introduced.

Hypothesis from earlier experimentation:
mounting `cgroup2` in a holder mount namespace
makes it a `MNT_LOCKED` child of `/sys` after the next userns-crossing copy,
covers the non-empty `/sys/fs/cgroup` directory
and breaks `mnt_already_visible()` for sysfs in containers.

In the previous docker pipeline `cgroup2` was mounted inside the
per-invocation mount ns layered by `unshare --cgroup --mount`
in `bin/ns-ai-dev-docker`. The task performing that `unshare` was in U2
(from the outer nsenter), while bwrap's mount ns is owned by U1 — so the very
copy that creates the docker-private mount ns crosses U1→U2 and locks bwrap's tree.
cgroup2 was mounted **after** that lock. The subsequent `unshare --mount --pid`
was within U2 (no userns crossing), so it copied the mount ns without adding new locks.
The strict reading of the rule predicted this should break sysfs in containers
(cgroup2 covers the non-empty `/sys/fs/cgroup`), but in practice containers ran normally.
Possible explanations (none confirmed):

- `bwrap --unshare-cgroup` (CLONE_NEWCGROUP) shifts the cgroup-namespace view
  enough that `mnt_already_visible()` does not flag the cgroup2 mount.
- The hypothesis was specific to mounting cgroup2 in a long-lived holder mount ns,
  not in a per-invocation child mount ns layered on top.
- The check has changed in a recent kernel.

### `net_current_may_mount` for sysfs

Mounting sysfs inside a container also passes through
`net_current_may_mount()`,
which checks `ns_capable(net->user_ns, CAP_SYS_ADMIN)` —
i.e., the caller must have `CAP_SYS_ADMIN` in the userns that owns the netns.

If the netns is owned by a userns the caller has no caps in,
the mount returns `EPERM` even when bwrap and lock_mnt_tree allow it.
This forces dockerd's userns to own (or be a parent of) the container's netns.

### mount procfs requires `CAP_SYS_ADMIN` in pid-ns owner userns

Mounting `proc` (`fs/proc/root.c` → `proc_get_tree` → `proc_fill_super`) checks
`ns_capable(pid_ns->user_ns, CAP_SYS_ADMIN)` — the caller must have
`CAP_SYS_ADMIN` in the userns that owns the **target pid namespace**, not the
caller's current userns.

This bites `docker run --pid=host` containers: they share dockerd's pid ns
instead of creating their own, then try to `mount -t proc` for the rootfs.

In this project, bwrap's pid ns (created by `--unshare-pid` from U1) is owned by U1.
If dockerd shares bwrap's pid ns, a `--pid=host` container in U2 has no caps in U1
and the procfs mount fails with `EPERM`:

```text
mount src=proc, dst=/proc, … flags=MS_NOSUID|MS_NODEV|MS_NOEXEC: operation not permitted
```

Fix: dockerd must run in a pid ns **owned by U2**, created by
`unshare --pid --fork` from a U2-resident task (i.e. after the outer nsenter).
Containers without `--pid=host` are unaffected because they create their own
pid ns via `CLONE_NEWPID` from dockerd in U2, owned by U2 either way.

`--mount` (required by `--mount-proc`) also gives dockerd its own mount namespace,
which is needed for overlay2: without it, `mount -t overlay` inside a userns
fails with `EPERM` because the shared mount ns is owned by U1,
and dockerd in U2 has no caps there.

### `unshare --pid --fork` ignores SIGTERM while waiting

`unshare --pid --fork` blocks in `waitpid()` on its forked child
and does not install a handler for SIGTERM —
the default disposition for SIGTERM is `Terminate`,
but the kernel does not deliver it to a process blocked in `waitpid()`
because `unshare` is not in a signal-handling context at that point;
the signal is left pending and `unshare` continues waiting.
(The exact mechanism: `unshare` calls `waitpid()` synchronously
and never reaches the point where pending signals are checked.)

As a result, `setpriv --pdeathsig SIGTERM` placed **before** `unshare --pid --fork`
does not produce the intended effect when the parent dies:
the kernel delivers SIGTERM to `unshare`,
but `unshare` ignores it while waiting on its child.

The correct approach is `setpriv --pdeathsig SIGKILL` before `unshare`:
SIGKILL cannot be caught or ignored, so `unshare` dies immediately,
and `--kill-child=SIGTERM` (which works via `prctl(PR_SET_PDEATHSIG)`)
ensures the forked child receives SIGTERM for graceful shutdown.

## bwrap

### bwrap monitor, init reaper, and inner sit in different namespaces

With `--unshare-pid` (and without `--as-pid-1`), `bwrap` produces a
**three-level** host process tree after its `clone()` for namespace creation:

- the **monitor** retains `bwrap`'s original PID and stays in the **caller's**
  mount ns (it never enters the new mount ns); its `waitpid(-1, …)` loop reaps
  zombies for the sandbox pid ns from outside.
- the **init reaper** is the first cloned child; it is PID 1 of the new pid ns
  and lives in bwrap's modified mount ns. Its sole job is to be PID 1 — when it
  dies the kernel destroys the pid ns and SIGKILLs every other process in it.
- the **inner** is the reaper's child; it does the per-mount setup
  (`pivot_root`, all `--bind` / `--ro-bind` / `--proc` / `--dev` / …) inside the
  new mount ns and then `execve()`s the user command, becoming PID 2.

`--as-pid-1` collapses the reaper layer (the user command itself becomes PID 1).
This project does not use `--as-pid-1`, so all three levels are present.

Concretely: `readlink /proc/<monitor>/ns/mnt ≠ readlink /proc/<reaper>/ns/mnt`,
while reaper and inner share the same mount ns.
A subsequent `nsenter --target <monitor> --mount` enters the **wrong** mount ns
(no bwrap layout applied), silently bypassing every isolation choice made via
bwrap arguments.

Always target the inner PID (the user command, post-execve) when joining a
long-lived bwrap holder via `nsenter --mount`. SIGKILL the reaper PID to tear
the whole sandbox down at once.

### `PR_SET_NO_NEW_PRIVS` neutralises setuid helpers inside bwrap

`bwrap` sets `PR_SET_NO_NEW_PRIVS` on its child by default.
Once that bit is on, `setuid` / `setgid` binaries no longer gain elevated credentials
on `execve` — they run with the caller's UID/GID.

Practical impact for this project:
SUID helpers like `newuidmap` / `newgidmap` cannot be invoked from inside bwrap
to write `uid_map` / `gid_map`.
Operations that need those helpers must run **outside** bwrap
(this is why `unshare --map-users auto / --map-current-user`
and the `nsenter --user $U1 -- bash <<EOF … >/proc/$U2/uid_map`
trick both happen on the host side, before any bwrap is launched).

Re-evaluate any future "rootless docker inside bwrap" attempt with this in mind:
if rootlesskit relies on `newuidmap`,
it will silently get the caller's caps instead of those granted by setuid
and will fail in non-obvious ways.

### `--ro-bind` creates intermediates as 0700 root

`bwrap` creates intermediate directories for `--bind` / `--ro-bind` targets
as mode `0700` owned by inner root.
Subsequent operations from a non-root inner user are then denied on those auto-created parents.

Workaround: pre-create the parent with `--dir /path` (mode 0755) before the bind.
Visible in this project on `/home`, `/run/udev`, `/run/dbus`, etc.

### `--ro-bind /sys` vs `--bind /sys`

`--ro-bind /sys` is the default safe choice
because it makes `mnt_already_visible()` reject sysfs mount inside `--privileged` containers
(MNT_LOCK_READONLY propagates and the sysfs check fails).
Switch to `--bind /sys` (rw) only if `--privileged` containers must mount sysfs.

### `bwrap` skips its own userns when caller is UID 0

`bwrap` checks `is_privileged` (`getuid() == 0` before `execve`, or
`real_uid == 0` inside the new process) to decide whether to create its own
child user namespace. When the caller is UID 0, bwrap reuses the caller's
userns instead of nesting.

`unshare --setuid 0 --setgid 0` before `bwrap` sets the child to inner UID 0.
The `unshare` process holds full `CAP_SETUID` / `CAP_SETGID` in the freshly
created userns (it is the namespace's creator), so the kernel's capability
check in `setresuid()` / `setresgid()` succeeds.
With identity sub-id mapping (inner 0 = host subuid start),
this "privileged" path has no host-level privileges —
outer UID 0 is unmapped, so inner UID 0 appears as overflow UID 65534
for host-root-owned resources.

## `setpriv`

- `setpriv --pdeathsig SIGNAL` translates to `prctl(PR_SET_PDEATHSIG, SIGNAL)`
  on the calling process.
  See "commit_creds resets pdeath_signal" above —
  it must come after any operation that gains caps (e.g. `nsenter --user`).
- `setpriv --reuid=N --regid=M --init-groups`
  is the standard way to drop from inner root to a regular UID
  while applying the supplementary groups defined in `/etc/group` for that UID.

## Shells and SSH

### `ControlPath` does not enforce master-only mode

Setting `ControlPath=/path` on an ordinary `ssh` client does **not** require a master
connection to exist.
If the control socket is missing or dead,
OpenSSH falls back to opening a normal standalone connection.

For this project,
that would silently create a fresh PAM/elogind session for `ai-dev`.
If a launcher must never do that,
it has to verify the dedicated master explicitly
(e.g. `ssh -O check ...`) and fail closed if the master is absent.

### A ControlMaster can outlive the session that created it

`ControlMaster` shares multiple sessions over one network connection.
Once other multiplexed clients exist,
the master process lifetime is no longer identical to the lifetime of any one
slave session.
If one local process must reflect the lifetime of one specific remote command,
do not make that process the ControlMaster itself.

### `ssh -T` does not detach inherited stdio

`ssh -T` disables pseudo-terminal allocation,
but it does not replace file descriptors 0, 1, and 2 inherited by the remote
shell.
If descendants keep those descriptors open,
the SSH session can remain alive after the original foreground command exits.
When the session lifetime must track only one foreground process,
redirect or otherwise replace stdio before `exec`ing the long-lived command.

## `dbus-daemon`

### Per-process GUID is generated and ignored in `--address` / `<listen>`

`dbus-daemon` generates a fresh GUID at startup
and **ignores** any `guid=<value>` passed via `--address` or in a `<listen>` config element.
Only `--print-address <fd>` reports the actual GUID.
sd-bus and other strict clients verify the GUID and reject connections with `EPERM` on mismatch,
so the address used by clients must come from `--print-address`.

### `--system` re-reads `/etc/dbus-1/system.conf`

`--system` triggers system-mode setup
that re-reads `/etc/dbus-1/system.conf`
and tries to drop privileges to the `messagebus` user.
For an unprivileged in-sandbox system bus
(no setuid, no `messagebus` user)
use `--config-file=...` with explicit `<type>system</type>` instead.

### `<standard_system_servicedirs/>` enables host-defined activation

`<standard_system_servicedirs/>` in a system bus config
wires in `/usr/share/dbus-1/system-services` etc.,
so any service the host knows about can be activated on demand.
Services that need real root / polkit / specific caps
will fail to activate under an unprivileged daemon —
that failure is acceptable; the way to block leaks from services that _do_ activate
is to mask the data source in the bwrap mount layout
(e.g. mask `/sys`, `/proc`, devices),
not to refuse to run the service.

## GnuPG

### The host socketdir is not reusable across `ai-dev`

A host-side `gpg-agent` socketdir must not be exposed to `ai-dev` unchanged.
Depending on how GnuPG was started,
that path may encode the host-side sandbox `GNUPGHOME`
or otherwise point into a location that `ai-dev` cannot traverse.

For this project,
the host-side helper must export a corrected socket path under `~ai-dev/.run/gnupg/`,
and the `ai-dev`-side expected socket path must point there.
Treat GnuPG as a special case,
not as another ordinary `XDG_RUNTIME_DIR` symlink.

## POSIX ACLs

### Default ACLs on Unix sockets still obey the creator's umask

A default ACL on `~ai-dev/.run/` can pre-grant `ai-dev` access to sockets
created there by host-side helpers,
so helper scripts do not need per-socket `wait` / `setfacl` logic.
But the effective ACL mask still comes from the creator's umask.
With the usual `022`,
the named `ai-dev` entry loses its write bit and `connect()` fails.

For this project,
helpers that create shared sockets under `~ai-dev/.run/` should run with
`umask 007`,
while `uid-ai-dev-runsvdir-session` installs the default ACL on the directory.

## `ip netns` and bind-mounting netns files

`ip netns` commands operate on names rooted at `/run/netns/<name>`.
To make an existing netns (held by some PID) reachable by name:

```sh
mkdir -p /run/netns
touch /run/netns/$name
mount --bind /proc/$pid/ns/net /run/netns/$name
```

Without the bind mount, `ip netns exec <name>` cannot find the namespace.
`umount` + `rm` of the file on cleanup.

## cgroup v2 delegation

cgroup v2 migration across sibling subtrees
requires write access to the **common ancestor's** `cgroup.procs`.
On non-systemd systems (this project: elogind/runit)
the user's session may live under a root-owned cgroup (e.g. `/1`),
so a sandbox-side service cannot move itself
into a delegated subtree without help.

The pattern used here: a small sudo helper
that verifies the target PID belongs to the caller
and writes the PID into the delegated cgroup's `cgroup.procs`.

## PID namespace constraints

- `xdg-desktop-portal` identifies callers via `SO_PEERCRED`,
  which only carries valid PIDs across processes that share a PID namespace.
  All sandboxed processes that need to talk to the portal
  must therefore live in the same PID namespace.
- For "host PID" escape vectors:
  the relevant PID 1 is whichever process is PID 1 in the **caller's** PID namespace,
  not the host's init.

### `/proc/<pid>/root` bypasses caller's mount ns

`/proc/<pid>/root` is a magic symlink pointing at the target's filesystem
root. Following it (path lookup, not just `readlink`) reads from the
target's mount namespace, _bypassing_ whatever layout the caller sits in;
access is gated by `ptrace_may_access` (`PTRACE_MODE_READ_FSCREDS`).

This means PID 1 of the sandbox pid namespace must live inside bwrap's
_modified_ mount ns. If PID 1 sat in a raw mount ns (e.g. when the pid ns
was created by `unshare --pid` _outside_ bwrap), `/proc/1/root` from inside
the sandbox would expose the host filesystem layout — and any holder
process running with the same UID as the user inside the sandbox would
satisfy ptrace_may_access's UID-match shortcut.

See ns/ARCHITECTURE.md § "Namespace layout" for the project-specific mitigation and access analysis.

## Container UID mapping under non-init dockerd

When dockerd runs in a non-init userns,
the container userns map is inherited from dockerd's own map.
Under identity sub-id mapping the container userns reproduces the parent userns verbatim —
no automatic shift is applied by containerd.
If a non-identity map is introduced, re-check the container map;
containerd may apply additional adjustments.

See ns/ARCHITECTURE.md § "U2" for empirical maps and UX consequences.
