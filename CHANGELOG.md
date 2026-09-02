# Changelog

All notable changes to this plugin are documented here.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and the project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).
The version in `manifest.json` is the source of truth and matches the git tag
for each release.

## [Unreleased]

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

[Unreleased]: https://github.com/samara-hub-ro/samara-tuf-keyboard-light/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/samara-hub-ro/samara-tuf-keyboard-light/releases/tag/v1.0.0
