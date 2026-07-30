# TermWire

The missing session layer between shells and terminal windows. A per-user
daemon owns every PTY; terminals become lightweight clients that attach to
those sessions. See [TermWire-Vision.md](TermWire-Vision.md) for the full
picture.

## Status

Early bring-up. Nothing here is usable yet.

## Building

Requires **Zig 0.16.0** (exactly — see below) and git submodules:

```sh
git submodule update --init --depth 1
zig build
zig-out/bin/termwired
```

`zig build test` runs all tests.

## Layout

```
daemon/       termwired — the per-user session daemon
protocol/     wire-format types shared by daemon and clients
cli/          tw — CLI client (new/ls/attach)
web/          browser client (xterm.js)
third_party/  vendored dependencies (git submodules)
zig-pkg/      Zig package cache (generated, gitignored)
```

## Vendored dependencies

- `third_party/ghostty` — provides the `ghostty-vt` Zig module (their
  terminal/VT engine, a.k.a. libghostty-vt) which the daemon imports as a
  path dependency. **Pinned to a commit on `main`**, not a release tag:
  the newest release (v1.3.1) requires Zig 0.15.2 while their `main`
  requires 0.16.0, and matching the system Zig won. Re-pin to a release
  tag once v1.3.2+ ships. Note Zig requires the *exact* version named in
  `minimum_zig_version` territory here — build-system APIs break between
  minor versions, so the Ghostty pin and the Zig version move together.
- `third_party/xterm.js` — pinned to release tag `6.0.0`. Used by the
  browser client in `web/`; requires a node build step (or vendoring its
  `dist/`), decided when `web/` lands.
