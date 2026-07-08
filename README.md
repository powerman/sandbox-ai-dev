# sandbox-ai-dev

[![License MIT](https://img.shields.io/badge/license-MIT-royalblue.svg)](LICENSE)
[![Go version](https://img.shields.io/github/go-mod/go-version/powerman/sandbox-ai-dev?color=blue)](https://go.dev/)
[![Test](https://img.shields.io/github/actions/workflow/status/powerman/sandbox-ai-dev/test.yml?label=test)](https://github.com/powerman/sandbox-ai-dev/actions/workflows/test.yml)
[![Coverage Status](https://raw.githubusercontent.com/powerman/sandbox-ai-dev/gh-badges/coverage.svg)](https://github.com/powerman/sandbox-ai-dev/actions/workflows/test.yml)
[![Go Report Card](https://goreportcard.com/badge/github.com/powerman/sandbox-ai-dev)](https://goreportcard.com/report/github.com/powerman/sandbox-ai-dev)
[![Release](https://img.shields.io/github/v/release/powerman/sandbox-ai-dev?color=blue)](https://github.com/powerman/sandbox-ai-dev/releases/latest)

![Linux | amd64 arm64](https://img.shields.io/badge/Linux-amd64%20arm64-royalblue)

**Secure AND convenient** sandbox for local development with AI Agents on Linux.

- It is **convenient** because you won't have to change your habits:
  you'll continue working mostly in same way as usually.
- It is **secure** because malicious AI Agent won't be able to make any real harm.

## Implementations

This repository provides two sandbox architectures,
because there are two fundamentally different ways to isolate AI tooling.

- [**uid** — Primary, recommended for most users.](uid/README.md)
  Sandbox under a dedicated system user.
  Creates a separate Linux user account (`ai-dev`) for the sandbox
  and relies on standard multi-user OS isolation:
  file permissions, session separation, and process ownership.
  Firewall rules and access proxies additionally restrict what this user can reach on the host.
  This is the easiest model to understand and deploy,
  and can plausibly be adapted to other operating systems.
  Its main downside is stronger dependence on correct host configuration
  (partially mitigated by the planned self-check in `uid/TODO-check.md`).
- [**ns** — Alternative, stronger on Linux, recommended for power users.](ns/README.md)
  Sandbox in Linux namespaces — the same technology that powers Docker containers.
  Uses `unshare`/`bwrap` to create isolated Linux contexts:
  its own network, its own process tree, and its own mount view.
  This provides stronger isolation by construction,
  but is more Linux-specific and lower-level than `uid`.
  The current implementation targets Linux systems without systemd
  and currently relies on elogind.

Both implementations share the same threat model and design philosophy.

### How to choose

- Choose `uid` if you are comfortable with standard OS mechanisms:
  a separate user account, file permissions, firewall rules,
  and proxied access to host services.
  This is the easier model to understand and deploy.
- Choose `ns` if you want container-level isolation using Linux namespaces:
  private network, process space, and filesystem view.
  Stronger isolation by construction,
  but Linux-specific and more low-level than `uid`.

### Comparison

| Dimension             | `uid`                                                                     | `ns`                                                             |
| --------------------- | ------------------------------------------------------------------------- | ---------------------------------------------------------------- |
| What is the sandbox?  | A dedicated system user (`ai-dev`)                                        | A set of Linux namespaces                                        |
| Isolation via         | Multi-user OS separation + host policy (firewall, ACLs, proxy)            | Namespace-level separation (user, mount, pid, network, uts, ipc) |
| Policy direction      | Starts from shared host, adds restrictions (blacklist)                    | Starts isolated, selectively grants access (whitelist)           |
| localhost             | Same-user TCP servers reachable via cgroup mark; firewall blocks the rest | Private (separate network namespace)                             |
| Docker                | Rootless (dockerd-rootless.sh)                                            | Rootful inside sandbox netns                                     |
| sudo helpers          | None                                                                      | Three (namespace init, cgroup, cleanup)                          |
| Portability direction | Plausible to adapt to other OSes                                          | Linux-specific                                                   |

### Why two architectures?

`uid` exists because this project needs a sandbox that users can quickly understand,
audit mentally, and adapt to their own systems
without first learning Linux namespaces internals.
It is the design with the best chance of broader adoption and future adaptation beyond Linux.

`ns` exists for users who want stronger isolation on Linux:
private network, process space, and filesystem view via namespaces,
rather than relying primarily on host-side rules around a separate user account.

## The Rationale: Why do you need to isolate AI Agents

- There is currently no way to protect against prompt injection and supply chain attacks.
  - This means your AI Agent may turn malicious at any time.
- Both VM and container use different OS/filesystem root
  which does not match your host OS and configuration.
  It's okay to do something in such an alternative environment,
  but doing all of your work there is not convenient.
  And if you'll configure it to be convenient then
  eventually you'll find yourself doing _everything_ there, not just work on projects -
  i.e. you'll just move everything from the host into VM/container and thus destroy isolation.
  - This means existing solutions like `docker sandbox` or Dev Container are not convenient.
- While some AI Agents (e.g. Claude Code) already provide sandbox for agent actions
  we use many different AI Agents, most of which does not provide sandbox, and even if they do
  it's impossible to keep configurations of all these sandboxes in sync and secure enough.
  Even worse, usually there is a way for an AI Agent to work around such a sandbox.
  - This means isolation should be external to AI Agent and common for all used apps.
- Using either separate user account or Linux namespaces you can
  keep access to host tools with their configuration,
  keep (restricted for security) access to host services (DE, notifications, browser, etc.),
  avoid constantly syncing your project files between host and VM/container…
  and at same time have good enough and secure isolation for your private files/secrets.

## The Threat Model

Critical threats (mitigation required), from most critical to least critical:

- **Confidential data leakage.** Both accidental and malicious.
  The agent may read and send to LLM API (or a hacker):
  - Names/contents of personal files in `$HOME`, `/tmp`, `/mnt`, etc.
  - User secrets (available in environment variables or files in `$HOME`).
    - Private SSH/GPG keys.
    - Tokens for various APIs.
  - Project secrets (available in project files).
- **Code injection to escape the sandbox** (without a kernel exploit).
  The agent may inject a backdoor into files that will later be executed outside the sandbox:
  - User files like `~/.bashrc`.
  - Project files that are not visible in `git diff` but will execute if the user enters the
    project directory: via git hooks, `mise.local.toml`, etc.
- **Unauthorized actions on behalf of the user:**
  - The agent can modify server configurations via SSH.
  - The agent can push to repositories.
  - The agent can send unwanted email.
  - The agent can send unwanted requests to third-party APIs:
    - Make changes to a remote project's database.
    - Create cloud resources.

Non-critical threats (mitigation optional):

- **Privilege escalation** (breaking out of the sandbox via a kernel exploit).
  - Negligible probability of a successful attack.
  - Cannot be solved without a VM, and using a VM is incompatible with preserving the host UX.
- **Code injection into project files.**
  - This is addressed by manual review plus prohibiting AI Agents from doing `git push`.
- **Data loss.** The agent may delete or corrupt the home directory.
  - Mitigated by daily backups outside the agent's reach.
- **Denial of Service (DoS).**
  - AI Agents do not work autonomously but together with the user, so if an agent
    starts something excessively resource-intensive, the user will notice and stop it.
- **Prompt injection and supply chain attacks.**
  - There is hardly anything that can be done about this beyond using a sandbox plus
    review before `git push`.
- **Bypassing the agent's built-in protections.**
  - There is hardly anything that can be done about this beyond using a sandbox.

## The Concept: Sandbox isolation

The idea is to keep using your favorite tools with same configuration as on the host,
including GUI apps with same look&feel, with access to host notifications, browser, sound -
but hide host processes, all user files except projects you're working on with AI Agents,
apply extra firewall rules, block clipboard snooping, listening to microphone and host sounds,
allow access only to sandbox secrets and protect against _accidental_ leaking of sandbox secrets.

There is only one sandbox instance (when sandbox is running) on the host,
but you can run any GUI/CLI apps inside the sandbox at any time: terminal/shell/IDE/etc.
All these apps will have full access to each other and to the sandbox services (e.g. docker),
but their access to host processes, filesystem and network will be restricted.

Both implementations differ in isolation mechanism
(see [uid/README.md](uid/README.md) and [ns/README.md](ns/README.md) for details)
but share these common principles:

- Proxied sockets to access real user's services:
  - `wlproxy` for secure access to Wayland compositor
    (protects from clipboard snooping, overlay attacks, screen capture, input injection).
  - `xdg-dbus-proxy` for secure host's session D-Bus (notification and open url only).
  - `ssh-agent` running on the host, so there are no SSH private keys on sandbox filesystem.
  - `gpg-agent` running on the host, so there are no GPG private keys on sandbox filesystem.
- Filesystem protection is based on these principles:
  - Daily backups (done outside of the sandbox and not accessible from inside of the sandbox).
  - Sandbox works with own `$XDG_RUNTIME_DIR`.
  - Sandbox works with own `$HOME` dir and have about no access to user's `$HOME`:
    - Some config files are synced/bind-mounted read-only from user's `$HOME` for convenience.
    - Your projects should be moved into sandbox's `$HOME`.
  - Read-write access only to sandbox's `$HOME` and sandbox's `$XDG_RUNTIME_DIR`.
  - Full read-only access to host's system dirs (including `/etc`, `/sys`, `/usr`, …).
  - You must not visit sandbox's `$HOME` from the host (neither `cd` nor access files).
    - If some project you're working on must be also used outside of the sandbox
      then you'll have to make a separate `git clone` in user's `$HOME` and sync with `git pull`.
    - Only exception from this rule is daily backups.
- Secrets protection requires full separation of sandbox-accessible secrets:
  - You'll need to create new GPG/SSH private keys for use in the sandbox.
    - These private keys are stored separately on the host.
    - These private keys should provide minimal access rights, required to work in the sandbox.
  - You'll need to create new API tokens and other secrets for use in the sandbox.
    - These secrets should be stored in sandbox's `gnome-keyring-daemon`.
  - Projects secrets should be stored encrypted in project files or remote services.
  - You'll need to write shell wrappers for some tools you're using to make sure their secrets
    are not stored in unencrypted config files, visible in `ps` output,
    or generally available in sandbox environment variables. Some examples:
    - use [zapper](https://github.com/hackerschoice/zapper)
      to remove arguments from the process list:

          zapper -f copilot-api start --github-token "$(secret-tool lookup …)"

    - use bwrap to inject token into virtual file:

          bwrap --die-with-parent --bind / / --dev /dev --chmod 01777 /dev/shm \
              --bind-data 3 ~/.local/share/copilot-api/github_token copilot-api start \
              3< <(secret-tool lookup …)

- Restricting access to audio capture (microphone and host sound) requires extra PipeWire and
  WirePlumber configuration on the host.

## Known limitations

### URL opening: bidirectional sandbox↔browser channel

When an app inside the sandbox opens a URL pointing to a local HTTP server
(e.g. `http://192.168.x.2:PORT`),
the request is handled by the host browser,
which loads the page and executes any JavaScript in it.
That JavaScript runs in the host browser context, **outside** of the sandbox network namespace.

This creates a bidirectional channel that a malicious AI Agent can exploit:

- **Port scanning.** JavaScript can probe `localhost` and the local network
  via `fetch()` with `mode: 'no-cors'`.
  Even though responses are blocked by CORS,
  timing differences reveal which ports are open (timing side-channel).

- **Blind SSRF via browser.** JavaScript can send `POST`/`PUT`/`DELETE` requests
  to `http://localhost:*` or `http://192.168.x.x` services that **lack CSRF protection**.
  Responses are not readable by the attacker (CORS blocks them),
  but the request itself is delivered and may trigger state changes.
  Potentially affected targets: admin panels (Router/Switch, Grafana, …),
  HTTP-accessible databases (CouchDB, Elasticsearch).

> [!WARNING]
>
> The sandbox firewall does **not** protect against this —
> the requests originate from the host browser.
> There is no practical mitigation available to the user
> (authentication does not help if the user is already logged in).
> These are accepted residual risks of the URL-opening feature.

### GPU DMA attack

GPU devices (`/dev/dri/card*`, `/dev/dri/renderD*`, `/dev/nvidia*`) passed into the sandbox
can perform DMA (Direct Memory Access) to host physical memory.
Without IOMMU, this allows a sandboxed process to read and write arbitrary host memory —
effectively escaping the sandbox.

Both DRM master nodes (`cardN`) and render nodes (`renderDN`) allow DMA:
render nodes are designed for unprivileged compute (Vulkan, OpenCL)
and accept command buffers directly, making DMA through them straightforward —
no need to compete for DRM master.
Nvidia devices (`/dev/nvidia0`, `/dev/nvidiactl`, `/dev/nvidia-uvm`) similarly
allow DMA through their ioctl interfaces.

> [!WARNING]
>
> **Enable IOMMU** (Intel VT-d / AMD-Vi) in BIOS/firmware and kernel.
> Verify the kernel config and cmdline:
>
> ```bash
> # Intel:
> grep -E 'CONFIG_IOMMU_SUPPORT|CONFIG_INTEL_IOMMU|CONFIG_DMAR_TABLE|CONFIG_IOMMU_DEFAULT_DMA' /boot/config-$(uname -r)
> #   CONFIG_IOMMU_SUPPORT=y          — IOMMU subsystem (required)
> #   CONFIG_INTEL_IOMMU=y            — Intel VT-d driver (required)
> #   CONFIG_DMAR_TABLE=y             — DMAR ACPI table parsing (required)
> #   CONFIG_IOMMU_DEFAULT_DMA_LAZY=y — or _STRICT; not PASSTHROUGH (required)
> # AMD:
> grep -E 'CONFIG_IOMMU_SUPPORT|CONFIG_AMD_IOMMU|CONFIG_IOMMU_DEFAULT_DMA' /boot/config-$(uname -r)
> #   CONFIG_IOMMU_SUPPORT=y          — IOMMU subsystem (required)
> #   CONFIG_AMD_IOMMU=y              — AMD-Vi driver (required)
> #   CONFIG_IOMMU_DEFAULT_DMA_LAZY=y — or _STRICT; not PASSTHROUGH (required)
> ```
>
> Kernel cmdline (both Intel and AMD):
>
> ```text
> intel_iommu=on iommu=pt   — enable VT-d with passthrough for non-device DMA
>
> amd_iommu=on iommu=pt     — enable AMD-Vi with passthrough for non-device DMA
> ```
>
> With IOMMU active, the kernel restricts GPU DMA to only memory regions
> explicitly mapped through the kernel DMA API,
> and a sandboxed process cannot alter IOMMU mappings
> (that requires privileges in `init_user_ns`).
>
> If IOMMU is unavailable, do not pass GPU devices into the sandbox
> (remove the `--dev-bind-try /dev/dri` and `--dev-bind-try /dev/nvidia*`
> lines from the startup script) — at the cost of losing GPU acceleration.

### Keyring password interception

The gnome-keyring password (used to unlock the keyring) can be intercepted inside the sandbox.
A malicious process inside the sandbox could eavesdrop on D-Bus traffic
and capture the password when it is entered via the `gcr-prompter` dialog.

> [!WARNING]
>
> **Use a unique password** for the sandbox gnome-keyring that is not reused elsewhere.
> If the password is unique, its interception grants no access beyond the sandbox secrets
> (which are already accessible inside the sandbox anyway).

### Wayland clipboard: focus-stealing fallback

The sandbox has access to the host Wayland compositor (via `wlproxy`, on a separate socket).
`wlproxy` blocks `ext_data_control_manager_v1`,
preventing silent clipboard access without keyboard focus,
but the standard `wl_data_device` protocol remains available.
A process inside the sandbox —
either a legitimate tool like `wl-paste` or a malicious one —
can create a tiny transparent window to grab keyboard focus
and read the clipboard via `wl_data_device`.

> [!WARNING]
>
> Set your compositor's focus stealing prevention to block this technique:
>
> - **KWin**: "Focus stealing prevention" to **Medium** or higher
>   (System Settings → Window Management → Window Behaviour → Focus → Focus stealing prevention).
> - **Mutter (GNOME)**: `gsettings set org.gnome.desktop.wm.preferences focus-new-windows 'strict'`
> - **Xfwm4 (Xfce)**: Enable "Activate focus stealing prevention" in Window Manager Tweaks → Focus.
>
> If no equivalent setting is available or enabled,
> avoid copying passwords and other sensitive data while the sandbox is running,
> and use password manager autofill where possible.
