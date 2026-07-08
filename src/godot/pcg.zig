//! PCG32 random number generator used by Godot's `RandomPCG`.
//! Ported from `thirdparty/misc/pcg.cpp`.

pub const default_inc: u64 = 1442695040888963407;

pub const Pcg32 = struct {
    state: u64 = 0,
    inc: u64 = default_inc,

    pub fn seed(self: *Pcg32, init_state: u64) void {
        self.state = 0;
        self.inc = (self.inc << 1) | 1;
        _ = self.nextU32();
        self.state +%= init_state;
        _ = self.nextU32();
    }

    pub fn nextU32(self: *Pcg32) u32 {
        const oldstate = self.state;
        self.state = oldstate *% 6364136223846793005 +% (self.inc | 1);
        const xorshifted: u32 = @truncate(((oldstate >> 18) ^ oldstate) >> 27);
        const rot: u32 = @truncate(oldstate >> 59);
        const rot5: u5 = @truncate(rot);
        const neg_rot: u5 = @truncate((@as(u32, 0) -% rot) & 31);
        return (xorshifted >> rot5) | (xorshifted << neg_rot);
    }
};

test "pcg deterministic sequence after seed" {
    var rng = Pcg32{};
    rng.seed(12345);
    try std.testing.expect(rng.nextU32() != 0);
}

const std = @import("std");
