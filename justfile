# TermWire task runner. Recipes echo their commands as they run;
# anything build-graph-shaped delegates to `zig build`.

# list available recipes
default:
    @just --list

# build all binaries (termwired, tw, termwire-webd)
build:
    zig build

# run all tests
test:
    zig build test

# run the daemon in the foreground
run: build
    zig-out/bin/termwired

# build the web client bundle into web/dist
web:
    npm --prefix web install --no-fund --no-audit
    npm --prefix web run build

# build everything and serve the web client on http://127.0.0.1:7181
serve: build web
    zig-out/bin/termwire-webd

# vite dev server with hot reload (expects `just serve` running for the WS bridge)
web-dev:
    npm --prefix web run dev

# create a session and attach this terminal to it
new: build
    zig-out/bin/tw new

# list sessions
ls: build
    zig-out/bin/tw ls

# attach this terminal to a session
attach id: build
    zig-out/bin/tw attach {{id}}

# kill a session
kill id: build
    zig-out/bin/tw kill {{id}}

# format Zig sources
fmt:
    zig fmt build.zig daemon protocol cli webd

# remove build artifacts
clean:
    rm -rf zig-out .zig-cache web/dist
