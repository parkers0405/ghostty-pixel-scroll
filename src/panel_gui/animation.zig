//! Panel slide and resize animations.
//!
//! Uses critically damped springs (same as neovim_gui/animation.zig) for:
//! - Slide-in/out when toggling the panel open/closed
//! - Drag handle resize with momentum
//! - Content scroll within the panel

const std = @import("std");

/// Critically damped spring that decays toward 0.
/// No oscillation, settles within `animation_length` seconds.
/// Identical to the Neovide-ported spring in neovim_gui.
pub const CriticallyDampedSpring = struct {
    const Self = @This();

    position: f32 = 0,
    velocity: f32 = 0,

    /// Advance the spring toward 0. Returns true while still moving.
    pub fn update(self: *Self, dt: f32, animation_length: f32) bool {
        if (animation_length <= dt) {
            self.reset();
            return false;
        }
        if (self.position == 0.0 and self.velocity == 0.0) return false;

        const omega = 4.0 / animation_length;
        const a = self.position;
        const b = self.position * omega + self.velocity;
        const c = @exp(-omega * dt);

        self.position = (a + b * dt) * c;
        self.velocity = c * (-a * omega - b * dt * omega + b);

        // Settle when close enough (low threshold for smooth tail)
        if (@abs(self.position) < 0.002 and @abs(self.velocity) < 0.1) {
            self.reset();
            return false;
        }

        return true;
    }

    pub fn reset(self: *Self) void {
        self.position = 0;
        self.velocity = 0;
    }
};

/// Panel slide animation state.
/// `progress` goes from 0.0 (fully closed) to 1.0 (fully open).
pub const SlideAnimation = struct {
    const Self = @This();

    /// Spring drives toward 0; we map 0 = target, offset = distance from target
    spring: CriticallyDampedSpring = .{},

    /// Target state: 1.0 = open, 0.0 = closed
    target: f32 = 0.0,

    /// Current progress (0 = closed, 1 = open)
    progress: f32 = 0.0,

    /// Duration of slide animation in seconds
    duration: f32 = 0.35,

    pub fn open(self: *Self) void {
        self.spring.position = self.progress - 1.0;
        self.target = 1.0;
    }

    pub fn close(self: *Self) void {
        self.spring.position = self.progress - 0.0;
        self.target = 0.0;
    }

    pub fn toggle(self: *Self) void {
        if (self.target >= 0.5) {
            self.close();
        } else {
            self.open();
        }
    }

    /// Returns true if still animating
    pub fn update(self: *Self, dt: f32) bool {
        const animating = self.spring.update(dt, self.duration);
        self.progress = self.target + self.spring.position;
        self.progress = std.math.clamp(self.progress, 0.0, 1.0);
        return animating;
    }

    pub fn isOpen(self: *const Self) bool {
        return self.target >= 0.5;
    }

    pub fn isFullyOpen(self: *const Self) bool {
        return self.progress >= 0.99;
    }

    pub fn isFullyClosed(self: *const Self) bool {
        return self.progress <= 0.01;
    }
};

test "SlideAnimation open/close" {
    var anim = SlideAnimation{};
    anim.open();

    var iterations: usize = 0;
    while (anim.update(1.0 / 60.0)) {
        iterations += 1;
        if (iterations > 1000) break;
    }
    // Should settle near 1.0
    try std.testing.expect(anim.progress > 0.95);

    anim.close();
    iterations = 0;
    while (anim.update(1.0 / 60.0)) {
        iterations += 1;
        if (iterations > 1000) break;
    }
    // Should settle near 0.0
    try std.testing.expect(anim.progress < 0.05);
}
