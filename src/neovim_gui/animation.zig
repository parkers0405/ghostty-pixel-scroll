//! Critically damped spring animation for smooth scrolling and cursor movement.
//! Ported from Neovide's spring implementation.

const std = @import("std");

/// Critically damped spring that decays toward 0.
/// No oscillation, settles within `animation_length` seconds.
pub const CriticallyDampedSpring = struct {
    const Self = @This();

    position: f32 = 0,
    velocity: f32 = 0,

    /// Advance the spring toward 0. Returns true while still moving.
    pub fn update(self: *Self, dt: f32, animation_length: f32, _: f32) bool {
        if (animation_length <= dt) {
            self.reset();
            return false;
        }
        if (self.position == 0.0) return false;

        const omega = 4.0 / animation_length;
        const a = self.position;
        const b = self.position * omega + self.velocity;
        const c = @exp(-omega * dt);

        self.position = (a + b * dt) * c;
        self.velocity = c * (-a * omega - b * dt * omega + b);

        // Close enough — snap to zero and stop. The residual (< 0.01 lines,
        // i.e. less than half a pixel) is invisible, but leaving it non-zero
        // causes the renderer to activate extra-row rendering and pollute
        // the statusline/margin cells.
        if (@abs(self.position) < 0.01) {
            self.position = 0;
            self.velocity = 0;
            return false;
        }

        return true;
    }

    pub fn reset(self: *Self) void {
        self.position = 0;
        self.velocity = 0;
    }
};

test "CriticallyDampedSpring basic" {
    var spring = CriticallyDampedSpring{};
    spring.position = -1.0;

    var iterations: usize = 0;
    while (spring.update(1.0 / 60.0, 0.3, 0.0)) {
        iterations += 1;
        if (iterations > 1000) break;
    }

    try std.testing.expect(spring.position == 0.0);
    try std.testing.expect(iterations > 0);
    try std.testing.expect(iterations < 100);
}

test "CriticallyDampedSpring no oscillation" {
    var spring = CriticallyDampedSpring{};
    spring.position = -5.0;

    var prev_pos = spring.position;
    var crossed_zero = false;

    while (spring.update(1.0 / 60.0, 0.3, 0.0)) {
        if (spring.position > 0 and prev_pos < 0) crossed_zero = true;
        if (spring.position < 0 and prev_pos > 0) crossed_zero = true;
        prev_pos = spring.position;
    }

    try std.testing.expect(!crossed_zero);
}
