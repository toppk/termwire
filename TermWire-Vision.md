# TermWire

## Vision

**TermWire** is a rethinking of the Unix terminal architecture.

The goal is **not** to build another terminal emulator. The goal is to
build the missing *session layer* that sits between shells and terminal
windows, much like PipeWire became the missing session layer for Linux
audio.

Traditional terminal emulators own PTYs directly. TermWire proposes that
a single per-user daemon owns every PTY while terminals become
lightweight clients that attach to those sessions.

Applications continue believing they are talking to a normal terminal.
Users continue believing they are using a normal terminal. Only the
architecture changes.

------------------------------------------------------------------------

# Motivation

Modern development no longer consists of a single shell.

A typical workflow contains:

-   Multiple AI agent sessions
-   Diagnostics running for hours
-   Build systems
-   SSH sessions
-   Database consoles
-   Monitoring jobs
-   Temporary experiments

These are not independent windows.

They are related to a single task.

Today's desktop has no concept of this relationship.

------------------------------------------------------------------------

# The Missing Abstraction

Unix historically uses:

Process → PTY → Terminal Window

The missing abstraction is:

Process → PTY → **Session Runtime (TermWire)** → Views

Views may include:

-   Native desktop terminal
-   Browser
-   Mobile phone
-   Shared collaboration session
-   AI agent
-   Read-only observer

The PTY no longer belongs to the window.

------------------------------------------------------------------------

# Inspiration

## ZFS: The "Layering Violation"

When ZFS combined RAID with the filesystem, many argued it violated
proper layering.

History showed the opposite.

The abstraction boundary had simply been drawn in the wrong place.

TermWire proposes a similar shift.

The historical boundary between:

-   shell
-   PTY
-   terminal emulator
-   tmux

was reasonable in the 1980s but is no longer the optimal architecture
for today's workflows.

This is not a layering violation.

It is moving the abstraction boundary.

------------------------------------------------------------------------

## PipeWire

PipeWire provides two important lessons.

### Lesson 1

Linux needed a central audio daemon.

Direct access to /dev/snd was no longer sufficient.

Likewise, direct ownership of PTYs by every terminal emulator is no
longer sufficient.

A per-user runtime is needed.

### Lesson 2

PulseAudio demonstrated that architecture matters.

The daemon must not become the bottleneck.

The data plane must stay lightweight while the control plane remains
separate.

TermWire should avoid making every byte flow through heavyweight policy
code.

------------------------------------------------------------------------

# Design Principles

## 1. Behave like XTerm

The default experience should feel indistinguishable from a traditional
terminal.

Everything should continue working:

-   shells
-   vim
-   emacs
-   htop
-   ssh
-   curses applications

New capabilities should be additive.

------------------------------------------------------------------------

## 2. Persistent Sessions

Closing a window never destroys the terminal.

Windows are merely views.

------------------------------------------------------------------------

## 3. Workspaces

The fundamental organizational object is the Workspace.

A workspace groups:

-   terminals
-   AI agents
-   notes
-   diagnostics
-   related sessions

The grouping is semantic rather than visual.

------------------------------------------------------------------------

## 4. Multiple Views

Any session may have:

-   one interactive controller
-   multiple read-only observers
-   browser views
-   mobile views
-   remote collaborators

Control can be handed between clients through a lease.

------------------------------------------------------------------------

## 5. AI Native

Agents should become first-class participants.

Instead of:

"Copy this command."

An agent should request:

"Create a terminal in this workspace and execute this command."

Subject to user approval.

------------------------------------------------------------------------

# Architecture

## Runtime

A long-running daemon owns:

-   PTYs
-   shells
-   workspace metadata
-   permissions
-   notifications

## Clients

Clients become interchangeable.

Possible clients:

-   Native GTK
-   Browser (XTerm.js)
-   CLI attach utility
-   Mobile
-   Embedded terminals

------------------------------------------------------------------------

# Protocol

Separate concerns.

## Data Plane

Responsible for:

-   keyboard input
-   PTY output
-   resize events
-   screen updates

Fast. Minimal. Predictable.

## Control Plane

Responsible for:

-   create terminal
-   attach
-   detach
-   rename
-   move workspace
-   permissions
-   collaboration
-   notifications

Structured API.

Never tunneled through escape sequences.

Unlike tmux, the control plane exists outside the terminal stream.

------------------------------------------------------------------------

# Why tmux Is Not Enough

tmux solved persistence.

It also demonstrated the limitations of embedding a control plane inside
a terminal protocol.

TermWire keeps the persistence while moving management outside the PTY.

------------------------------------------------------------------------

# Scrollback

Canonical scrollback belongs to the runtime.

Clients may present it differently while sharing the same history.

This enables:

-   search
-   bookmarks
-   synchronized history
-   remote viewing

without forcing tmux-style interaction.

------------------------------------------------------------------------

# Initial Milestones

## Phase 1

-   PTY daemon
-   create shell
-   browser client using XTerm.js
-   reconnect after closing browser

## Phase 2

-   workspace model
-   multiple attached clients
-   read-only observers
-   CLI management tool

## Phase 3

-   native desktop client
-   mobile client
-   collaboration
-   AI integration

------------------------------------------------------------------------

# Repository Layout

``` text
termwire/
    daemon/
    protocol/
    cli/
    web/
    third_party/
        ghostty/
```

Initially vendor Ghostty as a git submodule until its VT engine becomes
a standalone library.

------------------------------------------------------------------------

# Long-Term Vision

TermWire should become for terminals what PipeWire became for Linux
audio.

Applications stop owning PTYs.

Terminal emulators become clients.

Workspaces become first-class.

AI agents become peers.

The terminal evolves from a window into a shared, persistent execution
environment.

------------------------------------------------------------------------

# Guiding Philosophy

> Preserve everything users love about XTerm.
>
> Add everything modern development actually needs.
>
> Move the abstraction boundary without breaking Unix.
