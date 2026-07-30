//! Wire-format types shared by the TermWire daemon and its clients.
//!
//! Control plane: newline-delimited JSON over a Unix domain socket.
//! Data plane: raw bytes over a per-session socket (defined later).

pub const version: u32 = 0;

test {
    @import("std").testing.refAllDecls(@This());
}
