# TODO: `sandbox-ai-dev` installer

## Goal

Write a small Go utility named `sandbox-ai-dev`.
It should reduce the current manual work,
without turning into a package manager or a generic config manager.

The first version only needs these commands:

- `install`
- `activate`
- `deactivate`
- `check`
- `upgrade`
- `uninstall`

## Main idea

Split the workflow into two clearly different layers.

### `install`

`install` copies a trusted project payload into one directory tree,
by default under `/usr/local`.
It does not touch live files in `/etc` or `$HOME`.

Because of that,
`install` can safely run as root,
or inside a package build root.
It is closer to `install(1)` than to "configure my system".

### `activate`

`activate` copies files from the trusted installed payload into live locations,
and then runs the commands needed to make them active.
This is where implementation-specific logic lives.

That means:

- copy live user files into `$HOME`;
- copy live system files into `/etc`;
- reload current live state now;
- set up boot-time persistence if configured.

### `deactivate`

`deactivate` is the reverse of `activate`.
It undoes live state,
removes live copied files,
and disables boot-time persistence.

### `uninstall`

`uninstall` is the reverse of `install`.
It removes the trusted installed payload from `--dest`.
It must not pretend to be the reverse of `activate`.

If the project is active,
`uninstall` should refuse and tell the user to run `deactivate` first.
That keeps the model obvious.

## Distribution model

Ship one binary in GitHub Releases.
Embed installable files into that binary via `//go:embed`.

Also ship a `.tar.gz` with the same files in plain form (done automatically by GitHub).
That archive is for:

- manual installation;
- distro packagers;
- debugging what exactly is embedded into the binary.

The binary is the normal upstream installation path.
The archive is the plain source view of the same payload.

## Minimal scope for v1

### v1 must do

- Install the trusted payload under a chosen prefix.
- Use `/usr/local` as the default prefix.
- Support `install --dest` for alternate prefixes.
- Support aspect-based config instead of giant distro profiles.
- Require an explicit `uid` or `ns` argument for `activate`.
- Show exact privileged commands before running them.
- Support upgrades from previous installer-managed versions.
- Re-run `activate` during `upgrade` only if the project is active.
- Store only the minimum state needed for real features.
- Keep all installer state under the chosen `--dest` tree.

### v1 must not do

- Merge arbitrary existing user config files.
- Support every distro or every service manager.
- Keep metadata that no v1 feature actually uses.
- Implement skew handling that is impossible in v1.
- Hide `sudo` behind silent magic.
- Treat `install` and `activate` as the same operation.

## Prefix layout

For a normal upstream install,
`install --dest /usr/local` should create something like:

```text
/usr/local/bin/sandbox-ai-dev
/usr/local/bin/uid-ai-dev
/usr/local/bin/uid-ai-dev-startup
/usr/local/bin/uid-ai-dev-shutdown
/usr/local/bin/ns-ai-dev
/usr/local/bin/ns-ai-dev-startup
/usr/local/bin/ns-ai-dev-shutdown
/usr/local/libexec/sandbox-ai-dev/...
/usr/local/share/sandbox-ai-dev/config/...
/usr/local/share/sandbox-ai-dev/uid/...
/usr/local/share/sandbox-ai-dev/ns/...
/usr/local/share/sandbox-ai-dev/install-state.toml
/usr/local/share/sandbox-ai-dev/activate-state.toml
```

Paths inside installed files must not hardcode `/usr` or `/usr/local`.
Current scripts and helpers must be rewritten so they detect the install prefix
from their own location,
for example via `dirname "$0"` plus path normalization.
That keeps `install --dest` simple,
and makes package staging work naturally.

## Configuration model

Do not encode one profile like `gentoo-runit`.
The same distro can vary too much.

Instead,
use one small human-readable config file,
with independent aspects that matter for `activate`.
TOML is a good default.

Example `activate.toml`:

```toml
implementation = "uid"
user_services = "runit"
firewall = "nftables"
firewall_boot = "manual"
use_pipewire = true
use_ebpf_same_cgroup_mark = true
ebpf_boot = "manual"

[paths]
prefix = "/usr/local"
nftables_dir = "/etc/nftables"
dbus_system_policy_dir = "/etc/dbus-1/system.d"
sudoers_dir = "/etc/sudoers.d"

[commands]
system_dbus_reload = "sv h dbus"
pipewire_restart = "gentoo-pipewire-launcher restart & disown"
```

Commands should describe project actions directly.
If the user wants to run some external helper through a wrapper or through `mise`,
that should be solved outside this project,
for example by putting a wrapper in `~/.local/bin`.

The installer must try to auto-detect defaults.
The saved config remains the source of truth once the user reviews it.

`firewall_boot = "manual"` and `ebpf_boot = "manual"` must be supported.
That means:

- do not edit boot scripts automatically;
- print the exact manual step;
- keep `check` honest about what is and is not managed.

## Commands

### `install`

`install` copies embedded files under the chosen prefix only.
It does not modify live user or system config.

Typical usage:

```text
sudo sandbox-ai-dev install --dest /usr/local
```

Package build usage:

```text
sandbox-ai-dev install --dest "$pkgdir/usr"
```

The command should support `--dry-run`.
That is simpler than generating a temporary shell script in v1.
The dry run must print the exact file operations.

`install` should also write `install-state.toml` under the same prefix.
That file is what makes `install` better than plain `tar -x`.

### `activate`

`activate` must require an explicit implementation argument:

```text
sandbox-ai-dev activate uid
sandbox-ai-dev activate ns
```

It should read `activate.toml`,
copy live files from the installed prefix,
and then activate the live state.

For user-owned files,
examples are:

- copy `config/*` to `~/.config/sandbox-ai-dev/`;
- copy `uid/sandbox-home/*` to
  `~/.local/share/sandbox-ai-dev/uid/sandbox-home/`;
- copy PipeWire and WirePlumber files into `~/.config` and `~/.local/share`.

For system-owned files,
examples are:

- copy nftables snippets into `/etc/nftables/`;
- copy system D-Bus policy into `/etc/dbus-1/system.d/`;
- copy or update `/etc/sudoers.d/sandbox-ai-dev`.

After copying,
`activate` activates the relevant parts.
Examples:

- reload or apply nftables rules now;
- reload system D-Bus now;
- run `ebpf-same-cgroup-mark load` now if enabled;
- restart PipeWire now if enabled and safe.

`activate` must also handle boot-time persistence.
If a feature is configured as `manual`,
it must print the exact manual step instead of editing boot files.

`activate` should save enough information for a later `deactivate`.
At minimum,
that includes:

- implementation (`uid` or `ns`);
- user name;
- service manager kind;
- service names created or expected;
- the effective config used for activation.

This also prepares the design for future `start`, `stop`, and `restart` commands,
which may be added later but should not force another state redesign.

### `deactivate`

`deactivate` reverses the live effects of `activate`.
It should:

- stop or disable project user services;
- remove or undo boot-time integration;
- unload or revert live nftables and eBPF state where supported;
- remove live copied files from `/etc` and the current user's home.

If a step cannot be done safely in v1,
`deactivate` must stop and print the exact manual command.
It must not silently leave the project half-active.

### `check`

`check` is the only diagnostic command in v1.
It should answer both:

- "are the expected files in place?";
- "does the live system look activated?".

Without flags,
it should do everything useful without `sudo`.
With `--sudo`,
it may do privileged read-only probes.

Examples:

- do the expected files exist under the chosen prefix;
- do the expected live files exist in `/etc` and `$HOME`;
- does `/etc/sudoers.d/sandbox-ai-dev` parse;
- if nftables is enabled,
  does `nft list ruleset` show the expected live state;
- if eBPF is enabled,
  does the expected loaded state appear present.

`check` should have a concise normal output,
and a more detailed `--verbose` output.

### `upgrade`

`upgrade` is more than "copy new files into the prefix".
It must handle the cases that are realistic in v1,
without adding self-update complexity yet.

#### `upgrade --check`

`upgrade --check` should compare:

- the version embedded into the current running binary;
- the version recorded in `install-state.toml`.

It should print the result to stdout in a cron-friendly way.
That is enough for v1.

#### Binary was updated externally

If the current running `sandbox-ai-dev` binary version differs from the installed version,
for example because `mise` already updated the binary,
`upgrade` must treat the current binary as the source of truth.

In v1,
this is the main upgrade path.
No GitHub download is needed.

#### Payload refresh

`upgrade` must then:

- perform the work of `install` for the new version;
- remove files from the installed prefix that existed before but are no longer shipped;
- re-run `activate` if the project is currently active;
- leave it inactive if it was inactive before.

Because `activate` touches `$HOME`,
`upgrade` must run as the user,
not as root.
It may still use `sudo` for the prefix update or system phase.

Future versions may add a GitHub version check,
and later perhaps binary download,
but that is outside v1.

### `uninstall`

`uninstall` removes the trusted payload under `--dest`.
It is the reverse of `install`,
not the reverse of `activate`.

If `activate-state.toml` says the project is active,
`uninstall` should refuse and require `deactivate` first.

## Sudo model

### `install`

Running `install` as root is acceptable,
because it only writes under `--dest`.
That is also how distro packagers may use it.

### `activate`, `deactivate`, `upgrade`, `uninstall`

These commands should normally run as the target user,
because they may touch `$HOME`.
Only the system phase should go through `sudo`.

Before the privileged phase,
the command must print the exact commands.
Example:

```text
Will run with sudo:
  install -m 644 ... /etc/nftables/uid-ai-dev.nft
  install -m 644 ... /etc/dbus-1/system.d/uid-ai-dev.conf
  install -m 440 ... /etc/sudoers.d/sandbox-ai-dev
  visudo -cf /etc/sudoers.d/sandbox-ai-dev
  sv h dbus
  nft -f /etc/nftables/uid-ai-dev.nft
  ebpf-same-cgroup-mark load
```

Support `--dry-run` here too.
That gives the user a readable plan without inventing a temporary shell script in v1.

### `check`

`check --sudo` may run commands such as:

- `sudo nft list ruleset`;
- `sudo visudo -cf /etc/sudoers.d/sandbox-ai-dev`;
- service reload or probe commands where root is required.

Yes,
read-only privileged probes belong here.
That is the right place for them.

## `sudoers`

If `NOPASSWD` is needed,
write one dedicated file:

- `/etc/sudoers.d/sandbox-ai-dev`

That file must contain exact command paths only.
No globs.
No user-writable paths.

The installer should:

- print the file before install or update;
- validate it with `visudo -cf`;
- install helper executables into a root-owned trusted path first.

Installing everything under `/usr/local` by default helps here.
The allowed commands then point at a trusted root-owned prefix,
not at files in the repository or in the user's home.

## Transactionality

`install`, `activate`, `deactivate`, `upgrade`, and `uninstall` must be restartable.
If one of them fails,
it must not leave the system pretending that everything is fine.

The minimal v1 rule should be:

- create an `incomplete` marker before mutating files;
- replace the final state file only after success;
- remove the marker only after success;
- make `check` report which command did not finish,
  and tell the user to rerun it.

The resulting state should be:

- either the command finished successfully; or
- the command did not finish,
  and the tool clearly says which command to run again.

That is enough for v1.
No full rollback engine is required.

## State files

Keep state as small as possible.
Do not add `format_version` in v1.
Add it only when a real incompatible change appears.

Keep state under the chosen prefix,
not in `/var/lib`.
That avoids stepping outside `--dest`.

Use two files:

- `share/sandbox-ai-dev/install-state.toml`
- `share/sandbox-ai-dev/activate-state.toml`

### `install-state.toml`

This file is written by `install`.
Its job is to support `upgrade` and `uninstall`.

A minimal example:

```toml
installed_version = "0.1.0"
paths = [
  "bin/sandbox-ai-dev",
  "bin/uid-ai-dev",
  "libexec/sandbox-ai-dev/ns-ai-dev-init",
  "share/sandbox-ai-dev/uid/nftables/uid-ai-dev.nft",
]
```

Why each field is needed in v1:

- `installed_version`
  - so `upgrade` can tell what is currently installed.
- `paths`
  - so `upgrade` can remove obsolete installed files,
    and `uninstall` can remove what `install` created.

Paths should be relative to the chosen prefix.
That keeps the state portable and makes `--dest` natural.

### `activate-state.toml`

This file is written by `activate`.
Its job is to support `deactivate`,
conditional re-activation during `upgrade`,
and future `start`/`stop`/`restart` commands.

A minimal example:

```toml
active = true
implementation = "uid"
user = "powerman"
user_services = "runit"
service_names = ["uid-ai-dev-startup", "uid-ai-dev-wlproxy"]
```

Why each field is needed in v1:

- `active`
  - so `upgrade` knows whether it must re-run `activate`.
- `implementation`
  - so `deactivate` knows which live layout to undo.
- `user`
  - so another user on the same host can be warned clearly.
- `user_services`
  - so later code knows how those services are managed.
- `service_names`
  - so later `deactivate` and future `restart` logic know what to stop.

The effective activation config should also be stored next to this file,
for example as `last-activate.toml`.
That lets `deactivate` and `upgrade` use the same choices even if the user edits
`~/.config/sandbox-ai-dev/activate.toml` later.

## Distro packaging

Using `install --dest ...` should be enough for packagers.
Example:

```text
sandbox-ai-dev install --dest "$pkgdir/usr"
```

That stages the same trusted payload tree that upstream install uses,
just under the package build root.

The release `.tar.gz` remains useful for packagers who prefer not to execute the binary
at package build time.

## Future stages

### Stage 1

Make this model work for one real `uid` installation on Gentoo and one on Ubuntu.
Do not add more abstraction before that works.

### Stage 2

Do the same for `ns`.
Add only the extra logic it really needs.

### Stage 3

Only after that,
add nicer auto-detection,
future `start`/`stop`/`restart`,
more backends,
or richer uninstall and upgrade behavior.

## Acceptance criteria for v1

The first version is good enough when:

- `install --dest /usr/local` stages a trusted payload tree;
- `activate uid|ns` copies live files and activates them;
- `deactivate` undoes the live activation;
- `check` verifies the result,
  with deeper probes under `--sudo`;
- `upgrade` refreshes the installed prefix and re-activates only if needed;
- `uninstall` removes the installed prefix only after deactivation;
- distro packagers can use `install --dest ...` instead of needing a Makefile.
