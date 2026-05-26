# Audio capture mitigation

## Problem

The sandbox bind-mounts the host PipeWire socket (`pipewire-0`) directly.
Any process inside the sandbox can connect and record microphone input
or capture system audio from host applications — the socket has no per-client access control.

## Implemented: Restricted PipeWire socket + WirePlumber Lua access component

**Status: working (2026-05-14).**

A dedicated PipeWire socket on the host (`pipewire-sandbox-ai-dev`)
is created by a PipeWire config drop-in and tags connecting clients
with `pipewire.sec.socket = "pipewire-sandbox-ai-dev"`.
The PipeWire access module marks these clients as `"restricted"`.
WirePlumber's default access handler gives them `"rx"` on all objects
(read + execute, enough for playback).

A custom Lua component (`sandbox-ai-dev.lua`) then explicitly denies
permissions on individual `Audio/Source` and `Audio/Sink/Monitor` nodes
for sandbox clients — they receive `"-"` (no permissions) on those objects.

The PulseAudio compatibility socket (`pulse/native`) is not mounted
inside the sandbox (it would bypass the restriction).

### Host-side files

```
~/.config/pipewire/pipewire.conf.d/sandbox-ai-dev.conf
    — Adds pipewire-sandbox-ai-dev socket with custom props,
      configures access.socket for it as "restricted".

~/.config/wireplumber/wireplumber.conf.d/sandbox-ai-dev.conf
    — Registers the sandbox-ai-dev Lua component and
      requires it in the "main" profile.

~/.local/share/wireplumber/scripts/client/sandbox-ai-dev.lua
    — ObjectManager-based Lua script that watches for
      sandbox clients and Audio/Source nodes, denying access.
```

### Sandbox changes

- `bin/ns-ai-dev-startup`: bind-mounts `pipewire-sandbox-ai-dev`
  as `pipewire-0` inside the sandbox (no `PIPEWIRE_REMOTE` needed).
  No longer mounts `pulse/native`.

### Verification

```bash
# Inside sandbox — playback works:
pw-play /usr/share/sounds/freedesktop/stereo/bell.oga
# Inside sandbox — microphone capture is blocked (creates empty header-only .wav):
pw-cat --record /tmp/hijack.wav
# 44 bytes = WAV header only; no data because client cannot see source nodes.

# Inside sandbox — sink monitor capture produces 44 bytes (blocked):
pw-record --target "alsa_output.pci-0000_07_04.0.analog-stereo.monitor" /tmp/test.wav
```

> [!NOTE]
>
> Monitor capture (recording system audio output from the default sink)
> could not be verified on the host through PipeWire's native API:
> `pw-record --target="sink.monitor"` produced audio data (>44 bytes)
> on the host, but only faint noise, not the actual looped-back output —
> suggesting `.monitor` targeting may not work as expected
> with PipeWire native tools.
> Inside the sandbox the same command produces exactly 44 bytes (blocked),
> which is consistent with the Audio/Source restriction working,
> but this cannot be confirmed as "monitor blocked" until
> a working host-side PipeWire-native capture command is found.

### Known limitations

- `pw-cat --record` does not error out — it waits for a source node
  that never becomes visible. Hard to distinguish from a legit hang.
  The resulting 44-byte (empty) WAV is the symptom.
- Temporarily enabling microphone access is impractical
  (edit Lua script or config, restart pipewire/wireplumber,
  restart sandbox).
- No PulseAudio support inside the sandbox (not yet needed).
- The PulseAudio routing through `pipewire-pulse` on the host
  is unrestricted (not exposed inside the sandbox).
- WirePlumber logs are not visible by default
  (Gentoo's `gentoo-pipewire-launcher` does not log to a file
  unless `GENTOO_WIREPLUMBER_LOG` is configured).

## Alternative approaches not implemented

### B: Separate PipeWire daemon for sandbox

Run a second `pipewire` instance inside the sandbox (by analogy with dbus).
This daemon would have no ALSA devices (they are busy with the host daemon)
and receive audio output through a tunnel from the host PipeWire.

**Pros:**

- Complete isolation — only explicitly routed audio reaches the sandbox.

**Cons:**

- Complex — two PipeWire daemons on the same machine is unusual.
- The tunnel between two PipeWire instances requires advanced setup.
- A previous attempt at this approach failed.
- ALSA device conflict (both daemons can't open the same hardware).

### C: ALSA loopback device

Use `snd-aloop` to create a virtual ALSA card.
Host PipeWire outputs audio to the loopback's playback substream;
sandbox reads from the capture substream.
Sandbox gets access only to the loopback device
(no real microphones or sound cards).

**Pros:**

- Simple isolation — the loopback device carries only what is explicitly
  routed to it (the host controls this).
- A sandboxed PipeWire instance connected to the loopback would only
  hear the routed audio — no microphone or system audio exposure.

**Cons:**

- Requires routing host audio to both real speakers AND the loopback
  device. PipeWire combined-sink / multi-device routing is non-trivial.
- Requires ALSA in the sandbox (currently not needed).
