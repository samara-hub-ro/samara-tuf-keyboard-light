# Changelog

All notable changes to this plugin are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version in `manifest.json` is the source of truth and matches the git tag
for each release.

## [Unreleased]

## [1.1.0] — 2026-09-04

Security hardening, from the marketplace review of 1.0.0. The panel does the
same things; how it reaches the programs behind them, and what it is willing to
read, is what changed.

### Changed

- **Every command is bound to an absolute path** — `/usr/bin/brightnessctl`,
  `/usr/bin/asusctl`, `/usr/bin/omarchy-osd` — instead of a bare name resolved
  through `PATH`. A bar widget inherits the shell's environment, and a single
  `PATH` entry ahead of `/usr/bin` would be enough for a bare name to mean
  something else entirely.

- **The environment is built, not inherited.** `PATH` is pinned to
  `/usr/bin:/bin` and only the variables these three need to find the session
  are passed through: `HOME`, `USER`, `LOGNAME`, `XDG_RUNTIME_DIR`,
  `XDG_SESSION_ID`, `XDG_SESSION_TYPE`, `XDG_CURRENT_DESKTOP`,
  `WAYLAND_DISPLAY`, `DBUS_SESSION_BUS_ADDRESS`.

- **The Aura config is found without a shell.** The `sh -c` probe that globbed
  `/etc/asusd/aura_*.ron` through `ls | grep | head` is gone. The known
  keyboard configs are tried in order instead — `aura_tuf.ron`,
  `aura_laptop.ron`, `aura_scsi.ron`, `aura_ally.ron` — each one a literal in
  the source, the first that opens winning and the rest never touched. That
  removes an inherited environment, an unbounded read of a subprocess's output,
  and a process with no deadline that nothing cleaned up if the widget went
  away mid-probe.

  Hardware whose config is named something outside that list now shows
  brightness only, where the glob would have found it. Worth an issue if it is
  yours, with the output of `ls /etc/asusd/`.

### Added

- **Ceilings on every file read**, checked before anything is parsed: 64 bytes
  for the sysfs LED attributes and for the theme's `keyboard.rgb`, 128 KiB for
  the Aura config, and 8 KiB for the longest RON block the parser will walk —
  so an unbalanced parenthesis costs one short scan rather than a pass over the
  whole file. The real files are a handful of bytes and under two kilobytes.

## [1.0.0] — 2026-09-02

First public release.

### Added

- **Bar widget** for the Omarchy 4 Quickshell bar, controlling the ASUS
  keyboard backlight from a single icon.
- **Brightness** over the kernel LED (`/sys/class/leds/asus::kbd_backlight`)
  through `brightnessctl`, reaching logind by D-Bus — no root, no udev rule.
- **Effects** — Static, Breathe, Rainbow and Pulse — through `asusctl`, which
  talks to `asusd` over D-Bus with polkit. Each effect keeps its own colours in
  `asusd`'s config, so switching between them does not overwrite them.
- **Colour presets**, led by the active Omarchy theme's keyboard colour when the
  theme ships one, so the keyboard matches the desktop in one click. Breathe
  offers a second colour to fade towards.
- **Speed** control (Low / Med / High) for Breathe and Rainbow, stored in the
  widget's own settings because `asusd` accepts the argument but always
  persists `Med`.
- **Bar icon interactions** — left click opens the panel, right click toggles
  the light off and back to its last level, scroll steps brightness.
- **Keyboard control** while the panel is open: `←`/`→` step brightness,
  `Enter` toggles, `Tab` moves to the neighbouring panel, `Esc` closes.
- **Settings schema** in the manifest (`scrollToAdjust`, `hideWhenUnsupported`,
  `speed`), so Omarchy's plugin settings UI builds the form automatically.

### Notes on behaviour

- State is **read back from the hardware** rather than assumed. Brightness and
  colour are also changed outside the widget — Fn keys, `rog-control-center`,
  `omarchy theme set` — so the widget polls: every second while the panel is
  open, every five seconds while it is shut, and not at all on hardware with no
  backlight. Neither sysfs nor `asusd` delivers usable inotify events, since
  `asusd` rewrites its config atomically and replaces the inode.
- The **Aura config path is probed, not hardcoded**. `asusd` names it after the
  hardware it detected (`aura_tuf.ron`, `aura_laptop.ron`, …), and the
  `aura_anime.ron` / `aura_slash.ron` variants drive auxiliary displays rather
  than the keyboard. The probe repeats when the panel opens, so the widget also
  works when `asusd` starts after the shell.
- **Degrades instead of breaking.** With no `asusd`, the panel falls back to a
  brightness-only control and says so. With no backlight device at all, and
  `hideWhenUnsupported` left on, the widget hides itself — harmless in a shared
  config.

[Unreleased]: https://github.com/samara-hub-ro/samara-tuf-keyboard-light/compare/v1.1.0...HEAD
[1.1.0]: https://github.com/samara-hub-ro/samara-tuf-keyboard-light/releases/tag/v1.1.0
[1.0.0]: https://github.com/samara-hub-ro/samara-tuf-keyboard-light/releases/tag/v1.0.0
