# Implement `uid-ai-dev-check`

## Goals

`check` must be the fast fail-closed startup gate for the separate-user sandbox.
It must verify the small set of host assumptions that this design depends on.
It must also remain usable as a standalone command.

The first pass should optimize for:

- one host-side entry point;
- one simple suppression file;
- one plugin protocol for built-ins and user checks;
- the same directory scheme in `~/.local/share/sandbox-ai-dev` and `~/.config/sandbox-ai-dev`;
- parallel execution of independent checks;
- actual probes,
  not only file-mode inspection.

It must not turn into a generic system auditor.
It must stay focused on conditions that make `uid/` unsafe by accident.

## Keep the command model simple

Add a dedicated host-side command:

- `uid/bin/uid-ai-dev-check`

Do not overload `uid-ai-dev-startup` with `--check-only`.
A separate command keeps the UX obvious and keeps the code small.

User-visible behaviour:

- `uid-ai-dev-check`
  - runs built-ins and user checks;
  - prints all findings;
  - exits non-zero when an unsuppressed error is present.
- `uid-ai-dev-check --startup`
  - runs the same checks;
  - prints a shorter startup-oriented report.

The command name stays `check`.
Do not introduce `doctor` anywhere.

## Startup integration

Change `uid/bin/uid-ai-dev-startup` to this order:

1. `uid-ai-dev-shutdown` best-effort;
2. `uid-ai-dev-check --startup`;
3. `sync_configs`;
4. `sync_staged_home`;
5. start the shared long-lived SSH master;
6. `exec ai-dev uid-ai-dev-runsvdir-session`.

The check must run before any long-lived sandbox session is created.
That keeps startup fail-closed.

`uid-ai-dev-check` should not create another long-lived transport.
Its SSH usage should stay one-shot and self-contained,
so `uid-ai-dev-shutdown` does not need special check-specific cleanup logic.

In the first pass,
`uid-ai-dev` itself should not run `check` on every client invocation.
The gate belongs in startup,
not in the normal per-command path.

## Directory layout

Use the same naming scheme in both trees:

- `~/.local/share/sandbox-ai-dev/check/plugin.d/`
- `~/.local/share/sandbox-ai-dev/check/remote.d/`
- `~/.config/sandbox-ai-dev/check/plugin.d/`
- `~/.config/sandbox-ai-dev/check/remote.d/`

Meaning:

- `plugin.d/` contains host-side plugins;
- `remote.d/` contains remote-side plugins that will be copied into `ai-dev`
  before execution.

In the first pass,
all four directories should be flat.
Do not add recursive discovery.
Basename-based override rules are much easier to reason about.

## Overlay rules

For both `plugin.d/` and `remote.d/`,
start from `~/.local/share/sandbox-ai-dev/check/<kind>.d/`
and overlay `~/.config/sandbox-ai-dev/check/<kind>.d/` by basename.

Rules:

- if only the share file exists,
  use it;
- if only the config file exists,
  use it;
- if both exist,
  the config file wins;
- if the winning file is non-executable,
  it masks the other file and no plugin is run for that basename.

Non-executable files in all four directories are ignored by plugin discovery.
That same rule intentionally lets users disable a built-in plugin by dropping a
non-executable file with the same name into `~/.config/sandbox-ai-dev/check/<kind>.d/`.

The assembled view should still preserve non-executable files.
Plugins may keep helper files next to themselves,
and remote payload delivery should copy those helpers too.
The ignore rule applies only to discovery,
not to file assembly.

## Execution model

`uid-ai-dev-check` should reuse the same logic locally and remotely.
Do not introduce a separate runner script or a special alternate CLI mode just to
execute one flat plugin directory.

High-level flow:

1. assemble a temporary local `plugin.d/` tree from the overlaid host-side
   sources;
2. remove both target remote plugin directories first:
   `/home/ai-dev/.local/share/sandbox-ai-dev/check/plugin.d/` and
   `/home/ai-dev/.config/sandbox-ai-dev/check/plugin.d/`;
3. copy local `~/.local/share/sandbox-ai-dev/check/remote.d/` into remote
   `/home/ai-dev/.local/share/sandbox-ai-dev/check/plugin.d/`;
4. copy local `~/.config/sandbox-ai-dev/check/remote.d/` into remote
   `/home/ai-dev/.config/sandbox-ai-dev/check/plugin.d/`;
5. copy the current `uid-ai-dev-check` script into
   `/home/ai-dev/.local/share/sandbox-ai-dev/check/uid-ai-dev-check` too;
6. start the host-side run and the remote-side run in parallel;
7. aggregate both result streams,
   apply suppressions,
   and choose the exit code.

Remote execution should use ordinary one-shot SSH:

- `ssh -o ControlMaster=no ai-dev@localhost ...`

Do not build `check` around `ControlMaster=yes`.
Do not pass a check-specific `ControlPath` through the plugin protocol.
If some rare plugin truly needs additional SSH traffic,
it can manage that itself.

The remote invocation should run the copied `uid-ai-dev-check` normally,
not through a special mode.
That works because the remote side receives only `plugin.d/` content.
No `remote.d/` tree is copied there,
so the remote run naturally behaves like a plain local-only run and does not
recurse into another remote stage.

Do not copy `check.txt` to the remote side.
Suppressions remain host-side only.

## Result model

Every check,
built-in or user-provided,
should emit findings through the same protocol.

Each finding has these logical fields:

- severity;
- check ID;
- optional finding subject;
- message.

Severity rules:

- `error` blocks startup unless explicitly suppressed;
- `warn` never blocks startup;
- checker malfunctions are also fatal for startup.

The full finding ID is:

- `check_id` when the subject is empty;
- `check_id:subject` when the subject is present.

This intentionally matches the suppression syntax.

Recommended exit codes:

- `0` = no unsuppressed errors;
- `1` = one or more unsuppressed errors;
- `2` = checker malfunction,
  bad config permissions,
  malformed plugin output,
  unreadable required probe state,
  or plugin execution failure.

Use stable IDs from the start.
A suppression file is only workable if IDs do not churn.

Suggested naming style:

- check IDs: `group.topic`;
- finding IDs: `group.topic:subject`.

Examples:

- `host.hidepid`
- `dbus.system.deny:org.freedesktop.login1`
- `dbus.session.direct:/tmp/dbus-I0jFkl9p10`
- `log.readable:/var/log/rkhunter.log`
- `device.openable:/dev/fuse`

## Suppression config

Read only this host-side file:

- `~/.config/sandbox-ai-dev/check.txt`

Do not read suppressions from the repository,
from `uid/`,
or from `~ai-dev/`.
The startup gate must stay outside the sandbox's writable area.

The file is optional.
When present,
require all of these:

- owned by the host user or by root;
- not group-writable;
- not world-writable.

Unsafe permissions must fail closed.
Otherwise a third party could silently weaken startup checks.

Use a tiny line-based format.
No YAML,
no TOML,
no JSON parser.

Proposed syntax:

```text
# Disable a whole check.
host.hidepid

# Ignore one exact finding.
log.readable:/var/log/rkhunter.log

# Ignore a family of findings.
dbus.session.direct:/tmp/dbus-*
```

Semantics:

- a line without `:` matches check IDs;
- a line with `:` matches full finding IDs;
- `*` is supported anywhere in the pattern;
- patterns match the whole target string,
  not substrings;
- missing file means default policy with no suppressions.

This keeps the syntax tiny while still handling real cases such as
`/tmp/dbus-*`.
Do not add regex support in the first pass.
The wildcard layer is enough.

## Plugin sources

Built-in plugins and user plugins use the same runtime protocol.
The only difference is where they come from.

Built-ins come from:

- `~/.local/share/sandbox-ai-dev/check/plugin.d/`
- `~/.local/share/sandbox-ai-dev/check/remote.d/`

User overrides and user-specific additions come from:

- `~/.config/sandbox-ai-dev/check/plugin.d/`
- `~/.config/sandbox-ai-dev/check/remote.d/`

Ignore non-executable files during discovery in all four directories.
Those files may still be present as helpers in the assembled trees.

## Plugin environment

Provide these variables to every plugin:

- `AI_DEV_CHECK_MODE=startup|manual`
- `AI_DEV_CHECK_HOST_USER=<main user>`

For host-side plugins only,
also provide:

- `AI_DEV_CHECK_TARGET=ai-dev@localhost`

Do not add extra role-discovery variables until there is a concrete need.
In the ideal case,
local and remote plugins should not care where they are running.

## Plugin wire format

Use a tab-separated protocol with four logical fields:

```text
severity<TAB>check_id<TAB>finding_subject_b64<TAB>message_b64
```

Field rules:

- `severity` is `error` or `warn`;
- `check_id` never contains tabs;
- `finding_subject_b64` is Base64 for the raw subject bytes;
- `message_b64` is Base64 for the raw message bytes.

The first two fields stay plain text.
The last two fields are Base64 so the protocol does not need a custom escaping
language.
Plugins can rely on standard utilities like `base64` and `tr` instead of on a
project-specific helper.

The exact shell spelling used to feed bytes into `base64` is not part of this
spec.
Use whatever form is correct for the plugin's language and shell.
The only contract is the resulting tab-separated record.

The runner should decode the two Base64 fields after splitting the record.
Empty values may be encoded as empty fields.

A non-zero plugin exit status means the plugin itself failed.
That becomes a fatal synthetic finding for startup.
Malformed plugin output is also fatal.

## Parallel execution

Run all plugins,
built-in and user,
in parallel.
That is the main reason to keep built-ins in plugin form too.

Recommended execution model:

1. discover executable plugins in one flat directory;
2. sort them lexically for deterministic ordering;
3. start them all in parallel;
4. capture each plugin's stdout and stderr into its own temp file;
5. wait for all plugins;
6. parse outputs in the original lexical order;
7. emit one combined result stream.

The public `uid-ai-dev-check` then runs one host-side pass and one remote-side pass
in parallel and merges those two streams.
That gives fast execution without nondeterministic report ordering.

## Built-in blocking checks

These checks should emit `error` by default.
They are the core fail-closed gate.
In the implementation,
each one should be a built-in plugin.

### `host.hidepid`

Host-side check.
Verify that `/proc` is mounted with `hidepid=2`.
This is a hard requirement from the current security model.

### `fs.host-home-traverse`

Remote check as `ai-dev`.
Verify that `/home/$HOST_USER` is not traversable.
The check should test actual traversal,
not only mode bits seen from the host side.

### `fs.host-run-user-traverse`

Remote check as `ai-dev`.
Verify that `/run/user/<host uid>` is not traversable.
The plugin may derive the host UID from `AI_DEV_CHECK_HOST_USER`.
Probe actual access,
not only metadata.

### `net.nftables.active`

Host-side check.
Verify that the `inet ai-dev` table is loaded.
The first pass may validate the installed table directly.
If later needed,
add one active network probe as a second line of defence.

### `net.loopback.ebpf.attached`

Host-side check.
Verify that `ebpf-same-cgroup-mark` is loaded and attached at `/sys/fs/cgroup`.
At minimum, the check should confirm these programs are attached:

- `same_cgroup_bind4` as `cgroup_inet4_bind`
- `same_cgroup_bind6` as `cgroup_inet6_bind`
- `same_cgroup_connect4` as `cgroup_inet4_connect`
- `same_cgroup_connect6` as `cgroup_inet6_connect`

If the configured mark differs from the default,
this check should report the effective value in its message.

### `socket.docker.rootful`

Remote check as `ai-dev`.
A curated rootful Docker socket list must not be connectable.
Start with:

- `/run/docker.sock`
- `/var/run/docker.sock`

If a host has other sensitive local sockets,
user plugins can extend the list.

### `dbus.system.policy-file`

Host-side check.
Verify that `/etc/dbus-1/system.d/uid-ai-dev.conf` exists.
The file being present is not enough on its own,
but absence is a hard failure.

### `dbus.system.deny:*`

Remote check as `ai-dev`.
Run active deny probes on a curated list of forbidden host system-bus
services.
The check should prove that access is denied,
not merely that the policy file exists.

For the first pass,
shape the policy so the probe itself is safe.
The clean way is to deny whole destinations that the sandbox never needs,
for example:

- `org.freedesktop.login1`
- `org.freedesktop.Accounts`
- `org.freedesktop.UDisks2`
- `org.freedesktop.NetworkManager`
- `org.freedesktop.UPower`

Then the checker can safely call `org.freedesktop.DBus.Peer.Ping`
or `Introspect`
and require `AccessDenied`.
Do not probe dangerous mutating methods directly.
If one of those succeeded,
it could already be too late.

### `dbus.session.direct:*`

Remote check as `ai-dev`.
Direct host session-bus access outside the intended proxy path must not work.
The first pass should try the obvious shared-path candidates,
especially `/tmp/dbus-*` sockets,
and fail if a real D-Bus reply succeeds there.

The wildcard-heavy suppressions here are expected.
This check is the main reason the suppression syntax needs `*` support from day
one.

The proxy path under `~/.run/bus_host` is not the thing being denied here.
The check is specifically about bypass paths.

### `socket.mysql.auth-free`

Remote check as `ai-dev`.
If `/run/mysqld/mysqld.sock` exists and is connectable,
anonymous or otherwise auth-free access must fail.
This must be an active protocol probe,
not just a socket `connect()` test.

If pure shell becomes unreadable here,
ship one tiny remote-side helper next to the plugin in `remote.d/` and call it
locally from that plugin.
Do not build a large helper framework.

### `x11.direct`

Remote check as `ai-dev`.
Forcing direct host X11 access must still fail.
This should verify unusability,
not mere socket visibility.
A connectable abstract X11 socket is not enough to fail the check by itself.
A successful unauthorised X11 session is.

## Built-in warning checks

These checks should emit `warn` by default.
They should not block startup in the first pass,
but they are worth reporting.
They should also be implemented as built-in plugins.

### `docker.mountinfo.volume:*`

Remote check as `ai-dev`.
Report named Docker volume paths visible through mountinfo.
This is useful topology leakage,
but not strong enough to block startup by default.

### `log.readable:*`

Remote check as `ai-dev`.
Report readable host log files outside a small built-in allowlist.
Use full finding IDs so users can suppress one known path or pattern without
turning off the whole check.

### `device.openable:*`

Remote check as `ai-dev`.
Probe a curated list of device nodes,
and report newly openable ones.
This is mainly drift detection.
It should not be a default blocker unless a concrete host exploit path is proven.

### `socket.cups.metadata`

Remote check as `ai-dev`.
Report successful CUPS printer enumeration.
Keep it visible,
but do not block startup by default.

## Implementation shape

Keep `uid/bin/uid-ai-dev-check` as the small orchestrator.
It should do only these jobs:

- assemble the local overlay tree;
- assemble the remote overlay tree;
- copy the remote tree and the current `uid-ai-dev-check` script into `ai-dev`;
- run the host-side and remote-side passes in parallel;
- parse results;
- apply suppressions;
- print the report;
- choose the exit code.

The same script should be reused remotely without introducing a second runner or
an alternate CLI mode.
That is why the remote invocation must receive only `plugin.d/` and no
`remote.d/`.

Do not hard-code every built-in check as a shell function in the orchestrator.
The orchestrator should not care whether a check is built-in or user-provided.
That is why the built-ins should live in the same plugin model.

Do not add:

- a daemon;
- a background monitor;
- a cache of old results;
- a second service tree;
- a second plugin abstraction layer;
- a check-specific long-lived SSH transport;
- per-client checks inside `ai-dev`.

The feature should remain a fast startup gate plus a standalone command.
Nothing more.

## First implementation order

1. Add `uid/bin/uid-ai-dev-check` as the orchestrator.
2. Add built-in plugin directories under `uid/share/check/plugin.d/` and
   `uid/share/check/remote.d/`.
3. Implement flat overlay assembly for both `plugin.d/` and `remote.d/`.
4. Implement the host-side and remote-side pass logic inside the same script.
5. Implement `check.txt` parsing with whole-line patterns and `*` support.
6. Implement the tab-separated wire format with Base64 in the last two fields.
7. Implement host-side and remote-side parallel execution with deterministic
   output ordering.
8. Implement remote payload copy into both
   `/home/ai-dev/.local/share/sandbox-ai-dev/check/plugin.d/` and
   `/home/ai-dev/.config/sandbox-ai-dev/check/plugin.d/`,
   deleting both target directories first so stale files cannot survive from an
   older `remote.d/` layout.
9. Implement built-in plugins for the blocking and warning checks listed above.
10. Evaluate converting the current `check_secrets` logic from
    `uid/bin/uid-ai-dev-startup` into a host-side local plugin,
    and do that if it does not weaken its current coverage.
11. Hook `uid-ai-dev-check --startup` into `uid/bin/uid-ai-dev-startup` before the
    normal sync and before the long-lived master starts.
12. After the code lands,
    document the new command and paths in `uid/README.md` and the startup
    contract in `uid/ARCHITECTURE.md`.

The goal of the first pass is not perfect coverage.
The goal is to gate the short list of failures that would make the separate-user
sandbox unsafe by accident.
