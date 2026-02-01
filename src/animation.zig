//! Animation utilities for smooth cursor and scroll animations.
//! Implements critically damped spring physics like Neovide.

const std = @import("std");
const math = std.math;

/// A critically damped spring animation.
/// This provides smooth, non-oscillating motion toward a target.
/// Based on Neovide's implementation which uses a PD controller approach.
/// Reference: https://gdcvault.com/play/1027059/Math-In-Game-Development-Summit
pub const Spring = struct {
    /// Current position offset from target (0 = at target)
    position: f32 = 0,
    /// Current velocity
    velocity: f32 = 0,

    /// Update the spring animation.
    /// Returns true if still animating, false if settled.
    pub fn update(self: *Spring, dt: f32, animation_length: f32, zeta: f32) bool {
        // If animation would complete this frame, just snap
        if (animation_length <= dt) {
            self.reset();
            return false;
        }

        // Already at rest
        if (self.position == 0.0) {
            return false;
        }

        // Critically damped spring (zeta = 1)
        // No oscillation, fastest settling without overshoot
        // zeta passed as arg

        // Omega calculated so destination reached with ~2% tolerance in animation_length time
        const omega = 4.0 / (zeta * animation_length);

        // Analytical solution for critically damped harmonic oscillator
        // Initial conditions: a = initial position, b = initial_pos * omega + initial_vel
        const a = self.position;
        const b = self.position * omega + self.velocity;

        // Exponential decay factor
        const c = @exp(-omega * dt);

        // Update position and velocity
        self.position = (a + b * dt) * c;
        self.velocity = c * (-a * omega - b * dt * omega + b);

        // Snap to rest if close enough
        if (@abs(self.position) < 0.01) {
            self.reset();
            return false;
        }

        return true;
    }

    /// Reset to resting state
    pub fn reset(self: *Spring) void {
        self.position = 0;
        self.velocity = 0;
    }

    /// Set a new target by providing the delta from current actual position
    pub fn setTarget(self: *Spring, delta: f32) void {
        self.position = delta;
    }
};

/// 2D Spring for animating positions
pub const Spring2D = struct {
    x: Spring = .{},
    y: Spring = .{},

    pub fn update(self: *Spring2D, dt: f32, animation_length: f32, zeta: f32) bool {
        const animating_x = self.x.update(dt, animation_length, zeta);
        const animating_y = self.y.update(dt, animation_length, zeta);
        return animating_x or animating_y;
    }

    pub fn reset(self: *Spring2D) void {
        self.x.reset();
        self.y.reset();
    }

    pub fn setTarget(self: *Spring2D, dx: f32, dy: f32) void {
        self.x.setTarget(dx);
        self.y.setTarget(dy);
    }

    /// Get current offset from target
    pub fn getOffset(self: *const Spring2D) struct { x: f32, y: f32 } {
        return .{ .x = self.x.position, .y = self.y.position };
    }
};

/// Scroll animation state with momentum/inertia
pub const ScrollAnimation = struct {
    /// Current pixel offset (sub-line amount)
    pixel_offset: f32 = 0,
    /// Current velocity in pixels per second
    velocity: f32 = 0,
    /// Friction coefficient (velocity multiplier per second, e.g. 0.1 = 90% decay per second)
    friction: f32 = 0.05,
    /// Minimum velocity to continue animating
    min_velocity: f32 = 1.0,

    /// Update scroll animation with momentum.
    /// Returns true if still animating.
    pub fn update(self: *ScrollAnimation, dt: f32, cell_height: f32) struct {
        animating: bool,
        row_delta: i32,
        pixel_offset: f32,
    } {
        // Apply velocity to offset
        self.pixel_offset += self.velocity * dt;

        // Apply friction (exponential decay)
        // velocity = velocity * friction^dt
        // For dt=1s and friction=0.05, velocity becomes 5% of original
        self.velocity *= math.pow(f32, self.friction, dt);

        // Check if we've crossed row boundaries
        var row_delta: i32 = 0;
        while (self.pixel_offset >= cell_height) {
            self.pixel_offset -= cell_height;
            row_delta += 1;
        }
        while (self.pixel_offset < 0) {
            self.pixel_offset += cell_height;
            row_delta -= 1;
        }

        // Stop if velocity is too low
        const animating = @abs(self.velocity) >= self.min_velocity;
        if (!animating) {
            self.velocity = 0;
        }

        return .{
            .animating = animating,
            .row_delta = row_delta,
            .pixel_offset = self.pixel_offset,
        };
    }

    /// Add velocity from a scroll event (pixels per second)
    pub fn addVelocity(self: *ScrollAnimation, v: f32) void {
        self.velocity += v;
    }

    /// Set velocity directly (for immediate scroll input)
    pub fn setVelocity(self: *ScrollAnimation, v: f32) void {
        self.velocity = v;
    }

    /// Stop all animation
    pub fn stop(self: *ScrollAnimation) void {
        self.velocity = 0;
    }

    /// Check if currently animating
    pub fn isAnimating(self: *const ScrollAnimation) bool {
        return @abs(self.velocity) >= self.min_velocity;
    }
};

/// Cursor animation state
pub const CursorAnimation = struct {
    /// Current rendered position in pixels
    current_x: f32 = 0,
    current_y: f32 = 0,
    /// Target position in pixels
    target_x: f32 = 0,
    target_y: f32 = 0,
    /// Spring animations for smooth movement
    spring: Spring2D = .{},
    /// Animation duration in seconds
    animation_length: f32 = 0.15,
    /// Short animation for small movements (typing)
    short_animation_length: f32 = 0.04,
    /// Whether animation is enabled
    enabled: bool = true,

    /// Set a new target position
    pub fn setTarget(self: *CursorAnimation, x: f32, y: f32, cell_width: f32) void {
        if (!self.enabled) {
            self.current_x = x;
            self.current_y = y;
            self.target_x = x;
            self.target_y = y;
            return;
        }

        const dx = x - self.current_x;
        const dy = y - self.current_y;

        // Check if this is a small horizontal movement (typing)
        const is_small_jump = @abs(dx) <= cell_width * 2.5 and @abs(dy) < 0.001;
        _ = is_small_jump;

        // Set the spring to animate from current to target
        self.spring.setTarget(self.current_x - x, self.current_y - y);
        self.target_x = x;
        self.target_y = y;
    }

    /// Update animation state
    /// Returns true if still animating
    pub fn update(self: *CursorAnimation, dt: f32, animation_length: f32, zeta: f32) bool {
        if (!self.enabled) {
            return false;
        }

        const animating = self.spring.update(dt, animation_length, zeta);

        // Current position = target + spring offset
        const offset = self.spring.getOffset();
        self.current_x = self.target_x + offset.x;
        self.current_y = self.target_y + offset.y;

        return animating;
    }

    /// Get current rendered position
    pub fn getPosition(self: *const CursorAnimation) struct { x: f32, y: f32 } {
        return .{ .x = self.current_x, .y = self.current_y };
    }

    /// Snap to target immediately
    pub fn snap(self: *CursorAnimation) void {
        self.current_x = self.target_x;
        self.current_y = self.target_y;
        self.spring.reset();
    }
};

// Tests
test "spring settles to zero" {
    var spring = Spring{};
    spring.position = 100;
    spring.velocity = 0;

    var iterations: u32 = 0;
    while (spring.update(1.0 / 60.0, 0.15, 1.0)) {
        iterations += 1;
        if (iterations > 1000) break;
    }

    try std.testing.expect(spring.position == 0);
    try std.testing.expect(iterations < 100);
}

test "spring2d settles" {
    var spring = Spring2D{};
    spring.setTarget(100, 50);

    var iterations: u32 = 0;
    while (spring.update(1.0 / 60.0, 0.15, 1.0)) {
        iterations += 1;
        if (iterations > 1000) break;
    }

    const offset = spring.getOffset();
    try std.testing.expect(offset.x == 0);
    try std.testing.expect(offset.y == 0);
}

test "scroll animation momentum" {
    var scroll = ScrollAnimation{};
    scroll.velocity = 1000; // pixels per second

    const result = scroll.update(0.1, 20.0); // 100ms, 20px cell height
    try std.testing.expect(result.animating);
    try std.testing.expect(scroll.velocity < 1000); // Should have decayed
}
