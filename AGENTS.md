# General rules for the project

## Project Context (Reference)

### Nature of the project

The goal of the project is to create an environment (sandbox)
that is simultaneously **convenient** and **secure**
for developing any projects **together** with AI Agents.

An environment for AI Agents working autonomously is outside the scope of this project.

### Key system requirements

- Must work on Linux.
- Support for systems with elogind (without systemd) — the current cgroup may be root-owned.
- Wayland support; no X11 support (it is impossible to prevent sandbox escape via X11).
- The sandbox must be able to run:
  - GUI applications (e.g. a terminal, VS Code).
  - CLI/TUI applications (e.g. a shell, Claude Code).
- The sandbox requires unrestricted Docker access (rootless is fine).

### Design Philosophy

Working on projects with AI Agents should simplify life, not complicate it!
Ideally, the user's UX should be identical whether working on the host or inside the sandbox.

The user works on dozens of different projects using different languages.
A universal environment suitable for any project is therefore needed —
unlike a Dev Container, which describes an environment tailored to a single specific project.

The user already has a configured working environment on the host,
including IDEs with AI Agents (Neovim with AI plugins, VS Code + Copilot, Cursor, Zed, …),
CLI AI Agents (Claude Code, …), plus around a hundred common utilities —
many of which have user configs without which working becomes very inconvenient.

Many of these utilities are also used on the host,
so simply moving them into this environment is not possible
(including IDEs with either disabled AI plugins or using only local LLMs).
The configs for these utilities can occupy a large amount of space (around 300 MB, 3000 files).
Copying these configs into a container/VM and then (bidirectionally?) syncing with the host
would create significant inconvenience that should be avoided
(without introducing vulnerabilities).

### The Threat Model

The need for a sandbox that limits the possible damage from malicious AI Agent actions
arises for the following reasons:

- There is currently no known protection against prompt injection and supply chain attacks,
  so there is a high probability that an AI Agent will attempt to perform unwanted actions.
- An AI Agent can always bypass any internal restrictions or access controls.

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

### Secret Management

Any secrets accessible inside the sandbox are subject to malicious leakage.
It is therefore necessary to limit the sandbox's access to secrets
to the minimum required for operation.
It is also necessary to protect these secrets from accidental leakage during normal operation
(via inspecting environment variables or reading/grepping files).

User secrets must reside entirely outside the sandbox:

- Secrets that need to be accessible inside the sandbox are stored in a dedicated sandbox
  Secret Service (`gnome-keyring-daemon`). No other secrets are kept in this service.
- Inside the sandbox, secrets are accessed via the API (in an IDE) or the `secret-tool` utility.
- For utilities that need secrets (e.g. `gh`), wrappers are created in `~/.local/bin/` that
  load the secret into an environment variable and `exec` into the utility.
- SSH keys accessible to the sandbox are loaded into a dedicated `ssh-agent`
  running outside the sandbox.
  - The directory containing these SSH keys is located outside the sandbox.
  - These keys must be created specifically for use in the sandbox, and the actions they allow
    should be as restricted as possible (ideally — GitHub only).
  - When server access is needed, try to further restrict such keys:
    - Use separate keys that require confirmation when used (`ssh-add -c`).
    - Where possible, restrict these keys on servers via options in `~/.ssh/authorized_keys2`.
- GnuPG keys accessible to the sandbox are loaded into a dedicated `gpg-agent`
  running outside the sandbox.
  - The directory containing secret GPG keys is located outside the sandbox.
  - Inside the sandbox, `~/.gnupg/` contains only the public part of these keys.
  - These keys must be created specifically for use in the sandbox, and the actions they allow
    should be as restricted as possible (ideally — signing for commits only).

The location and format of project secrets depends on the specific project's implementation:

- It is preferable to store secrets in encrypted files.
- It is preferable to load decrypted secrets into environment variables immediately before
  running the project command that needs them.
- It is preferable to avoid writing decrypted secrets to temporary files.
  - If this is unavoidable, minimize the lifetime of such files and prevent accidental access:
    - Create a temporary directory with permissions 0100.
    - Store secrets inside that directory in a file/subdirectory with a random name.
- The key for decrypting project secrets is preferably stored in the same Secret Service.
  - This may not always be possible — some projects may require, for example, using the `age`
    utility and storing the private key in a file like `~/.config/…/age.txt`.
    In such cases, an accidental leak will most likely expose either the private key or
    the secrets encrypted with it, but not both simultaneously, which reduces the risk.
- When working with third-party projects it is impossible to control how they store secrets,
  so in practice some projects may store secrets in unencrypted files or environment variables.
  In such cases it will not be possible to protect them from accidental leakage.

### Sandbox Implementation

The project has two alternative sandbox implementations located in
`uid/` (primary, recommended, based on a dedicated system user plus host-side policy)
and `ns/` (Linux namespace-based, stronger on Linux).

Simultaneous installation of both variants is not supported
(project directories would need duplication and pipewire configs conflict).

Common to both implementations:

- The user manually controls access to secrets as described above.
- The user on the host avoids interacting with project directories accessible in the sandbox:
  - If the user needs to work on the same project outside the sandbox
    (e.g. to use prod secrets),
    they work with a separate clone of that project's repo, syncing with the sandbox version
    via `git pull`. This protects against git hooks, `mise.local.toml`, etc.
  - Any applications that are installed or updated inside the sandbox must not be run outside
    the sandbox. This means duplicating inside the sandbox the directories into which utilities
    like `mise` and Neovim plugins like Mason and tree-sitter install things.
- Access to D-Bus services is restricted:
  - A dedicated `dbus-daemon` runs inside the sandbox as the sandbox's session D-Bus.
  - An additional session D-Bus for the sandbox is provided via a restricted `xdg-dbus-proxy`
    running on the host, giving access to the host's session D-Bus only for
    `xdg-open` (URL opening) and sending notifications from inside the sandbox.
- The Docker service accessible from the sandbox must run:
  - Not under the real host root.
  - In an identical sandbox filesystem environment, so that container bind-mounts cannot
    give access to files that are not accessible inside the sandbox.
- Sending unwanted email from the sandbox is blocked by the firewall and by the absence of
  access to the host's `/var/spool/postfix`.
- Use of unwanted APIs is partially blocked by:
  - The absence inside the sandbox of the necessary secrets.
  - The firewall (which allows only http/https without restriction; other rules are added
    only when there is a genuine need for specific projects).

#### uid

- The sandbox has its own home directory, which the main user account cannot access.
- OS ACLs are the primary isolation mechanism for files and service sockets
  accessible in the sandbox.
- Access to the user's personal files is restricted via one-way sync:
  - User configs (via rsync or read-only bindfs).
- An additional config for the system D-Bus restricts the sandbox user's access.
- A firewall rule tied to the sandbox user's UID restricts both the user and their Docker.

#### ns

- The sandbox has its own home directory that the user will not accidentally enter.
  - Either this directory is placed outside the user's home: `/home/user.sandbox/`.
  - Or it is located at `/home/user/.sandbox/<RANDOM>/` plus `chmod 0100 ~/.sandbox`.
- Linux namespaces are the primary isolation mechanism.
  `bwrap` builds the sandbox mount layout used by this implementation.
- Access to the user's personal files is restricted by mounting into `bwrap` only:
  - Directories with projects needed inside the sandbox
    (`--bind` of the sandbox home directory).
  - User configs (`--ro-bind`).
- A dedicated `dbus-daemon` runs inside the sandbox as the system D-Bus for the sandbox.
- A separate network namespace for the sandbox and the Docker service for the shared firewall.

### Documentation map

For tasks that touch namespaces, capabilities, UID/GID mapping, mount layout,
or any sandbox-security concern,
**reading both ARCHITECTURE and GOTCHAS is mandatory** before making changes:

- When working inside a specific implementation tree,
  also read its local instructions:
  - `uid/AGENTS.md` — separate-user sandbox install paths,
    entry/exit points, and helper services.
  - `ns/AGENTS.md` — namespace-based sandbox install paths,
    entry/exit points, and sync points.
- [uid/ARCHITECTURE](uid/ARCHITECTURE.md) — architecture, lifecycle, and services.
- [ns/ARCHITECTURE](ns/ARCHITECTURE.md) — namespace topology, UID/GID maps,
  lifecycle phases, what-lives-where table, network stack, process trees.
  Update it together with any change to those areas.
- [GOTCHAS](GOTCHAS.md) — Linux/kernel/tooling behaviour the project relies on
  (mount lock semantics, userns mapping, dbus-daemon GUID, setpriv/pdeathsig ordering, etc.).
  Add new entries when you discover non-obvious kernel/tool behaviour;
  do not let those details rot in script comments or commit messages.

### Tasks

Use these commands for corresponding tasks:

- `mise run fmt` — fixes formatting, runs `chmod +x`.
- `mise run lint` — runs all linters.

---

## Mandatory Rules

### Repository Safety

- DO NOT create, amend, squash, rebase,
  or otherwise modify existing commits.
- DO NOT switch branches.
- DO NOT perform any network git operations
  inside this repository
  (e.g. `git push`, `git pull`, `git fetch`).
- You MAY use `git stash` if necessary,
  but clean up after yourself.
- You MAY use `git restore` for reverting local changes.
- Do not delete, rewrite, or mass-modify files
  outside the explicit scope of the task.
- Avoid destructive shell commands
  (e.g. `rm -rf`, recursive operations)
  unless explicitly required.

### Shell Script Minimalism

- Keep shell scripts as small and direct as possible.
- Do NOT turn simple launchers into supervisors.
  If lifecycle control belongs to an explicit shutdown command or the host service manager,
  keep it there.
- Do NOT add `trap` handlers,
  signal-forwarding glue,
  PID bookkeeping,
  custom exit-status plumbing,
  polling loops,
  `wait_for_*` helpers,
  manual socket deletion,
  `fuser -k`,
  or other defensive shell machinery
  unless a concrete reproduced failure requires exactly that code.
- Prefer one direct `exec` of the real process over wrapper logic.
  If the script only starts one long-lived command,
  extra shell structure is probably wrong.
- When a readiness check is truly needed,
  use the smallest predicate that matches the real dependency.
  Do NOT stack equivalent checks just to feel safer.
- Before adding any non-trivial shell branch or helper function,
  first prove that a simpler script is insufficient.
  If you cannot name the exact failure mode,
  do not add the code.

### Configuration Separation

Values that depend on the target environment
must be kept in `config/` files, not hardcoded in scripts.

These include:

- **Hardware** — GPU devices (NVIDIA, etc.), device paths.
- **Distro** — paths to system utilities, location of nftables rules
  and sudo helpers, cgroup hierarchy, rootfix paths.
- **Network** — subnet for the sandbox veth pair,
  firewall allowlist entries (llama-swap, etc.).
- **User files** — which host paths to sync into the sandbox
  (`sync-paths`, already done).

Hardcoded values are acceptable for:

- Architecture constants that never change between installations
  (e.g. well-known Wayland protocol names for wlproxy).
- Security policy that should not be user-tunable
  (e.g. wlproxy blocklist, D-Bus proxy filters).
- Names that are part of the deployment identity
  (e.g. the sandbox user `ai-dev`).

### Coding Standards

#### Semantic Linefeeds (comments and documentation only)

Start each sentence on a new line.
Break long sentences at natural pauses —
after commas, semicolons, conjunctions,
or between logical clauses.
Do NOT hard-wrap to a fixed column width.
The goal is meaningful diffs:
one changed idea = one changed line.

NOTE: The above example does not mean you should break into very short lines as shown.

#### Documentation (markdown)

- Write new documentation in English.
- Avoid adding new documentation
  unless specifically requested by user.
- Update existing documentation together with code changes
  ONLY if otherwise existing documentation became incorrect.
- Keep lines within 96 characters.
  Do NOT break semantically single line unless it won't fit into 96 characters.

#### Commenting

- Write new comments in English.
- Do not add redundant comments
  that restate obvious code behavior.
- Explain rationale, intent, trade-offs,
  and non-obvious behavior.
- Use full sentences in comments and documentation.
- Keep lines within 96 characters.
  Do NOT break semantically single line unless it won't fit into 96 characters.
- NEVER include architecture details and namespace-related gotchas into comments,
  add them into corresponding documentation files instead!
  Script comments may only refer docs on these topics, not duplicate or replace it.

## Recommended Practices

Apply these unless the task explicitly requires otherwise.

### Architecture changes

This is an extremely complex task — you must not underestimate this FACT!
Your understanding of how Linux namespaces work very often does not match reality,
so spending a long time reasoning through hypotheses is extremely inefficient.
You MUST approach this differently:

- Act in VERY small steps; verify hypotheses before relying on them.
- Where possible, verify all hypotheses by running commands
  (including test commands that show the current state of namespace/uid/capabilities/…);
  ask the user to run such commands on the host if the sandbox interferes with running them.
- Do NOT "recall" kernel source code — look at the current implementation in `/usr/src/linux/`.
