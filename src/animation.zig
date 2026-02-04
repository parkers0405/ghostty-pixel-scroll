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

/// Neovide-style corner-based cursor animation
/// The cursor is rendered as a quad with 4 independently animated corners.
/// Front corners (in direction of movement) animate faster than back corners,
/// creating a stretchy trail effect.
pub const CornerCursorAnimation = struct {
    /// Corner positions relative to cursor center (-0.5 to 0.5 for each axis)
    /// Order: top-left, top-right, bottom-right, bottom-left
    const STANDARD_CORNERS: [4][2]f32 = .{
        .{ -0.5, -0.5 }, // top-left
        .{ 0.5, -0.5 }, // top-right
        .{ 0.5, 0.5 }, // bottom-right
        .{ -0.5, 0.5 }, // bottom-left
    };

    /// Corner state
    const Corner = struct {
        /// Current pixel position
        current: [2]f32 = .{ 0, 0 },
        /// Previous destination (to detect changes)
        prev_dest: [2]f32 = .{ 0, 0 },
        /// Spring for X animation
        spring_x: Spring = .{},
        /// Spring for Y animation
        spring_y: Spring = .{},
        /// Animation length for this corner (varies based on direction)
        anim_length: f32 = 0.15,
        /// Relative position within cell (-0.5 to 0.5)
        relative_pos: [2]f32 = .{ 0, 0 },

        fn update(self: *Corner, dt: f32, dest: [2]f32, cursor_width: f32, cursor_height: f32) bool {
            // Calculate corner destination
            const corner_dest: [2]f32 = .{
                dest[0] + (self.relative_pos[0] + 0.5) * cursor_width,
                dest[1] + (self.relative_pos[1] + 0.5) * cursor_height,
            };

            // Check if destination changed
            if (corner_dest[0] != self.prev_dest[0] or corner_dest[1] != self.prev_dest[1]) {
                // Set spring to animate from current to new destination
                self.spring_x.position = self.current[0] - corner_dest[0];
                self.spring_y.position = self.current[1] - corner_dest[1];
                self.prev_dest = corner_dest;
            }

            // Update springs
            var animating = self.spring_x.update(dt, self.anim_length, 1.0);
            animating = self.spring_y.update(dt, self.anim_length, 1.0) or animating;

            // Current position = destination + spring offset
            self.current[0] = corner_dest[0] + self.spring_x.position;
            self.current[1] = corner_dest[1] + self.spring_y.position;

            return animating;
        }
    };

    /// The 4 corners
    corners: [4]Corner = undefined,
    /// Target position (top-left of cursor cell in pixels)
    target: [2]f32 = .{ 0, 0 },
    /// Previous target (to detect jumps)
    prev_target: [2]f32 = .{ 0, 0 },
    /// Base animation length
    animation_length: f32 = 0.15,
    /// Short animation for small movements
    short_animation_length: f32 = 0.04,
    /// Trail size (0.0 = no trail, 1.0 = full trail)
    trail_size: f32 = 0.7,
    /// Whether animation is enabled
    enabled: bool = true,

    pub fn init() CornerCursorAnimation {
        var self = CornerCursorAnimation{};
        for (0..4) |i| {
            self.corners[i] = Corner{
                .relative_pos = STANDARD_CORNERS[i],
            };
        }
        return self;
    }

    /// Set new target position and calculate corner animation lengths based on direction
    pub fn setTarget(self: *CornerCursorAnimation, x: f32, y: f32, cell_width: f32, cell_height: f32) void {
        if (!self.enabled) {
            self.target = .{ x, y };
            self.prev_target = .{ x, y };
            for (&self.corners) |*corner| {
                corner.current = .{
                    x + (corner.relative_pos[0] + 0.5) * cell_width,
                    y + (corner.relative_pos[1] + 0.5) * cell_height,
                };
            }
            return;
        }

        const dx = x - self.prev_target[0];
        const dy = y - self.prev_target[1];

        // Check if this is a small horizontal movement (typing)
        const is_small_jump = @abs(dx) <= cell_width * 2.5 and @abs(dy) < 0.001;

        // Calculate direction vector (normalized-ish)
        const dist = @sqrt(dx * dx + dy * dy);
        const dir_x = if (dist > 0.001) dx / dist else 0;
        const dir_y = if (dist > 0.001) dy / dist else 0;

        // Rank corners by alignment with movement direction
        // Corners more aligned with direction get faster animation (leading edge)
        for (&self.corners) |*corner| {
            // Corner direction from center
            const cx = corner.relative_pos[0];
            const cy = corner.relative_pos[1];

            // Dot product with movement direction
            const dot = cx * dir_x + cy * dir_y;

            // Rank: higher dot = more aligned = faster animation
            // dot ranges from ~-0.7 to ~0.7
            // Map to animation length: leading (dot > 0) = fast, trailing (dot < 0) = slow
            const base_len = if (is_small_jump)
                self.short_animation_length
            else
                self.animation_length;

            const leading_len = base_len * (1.0 - self.trail_size);
            const trailing_len = base_len;

            // Interpolate between leading and trailing based on dot
            const t = (dot + 0.7) / 1.4; // Normalize to 0..1
            corner.anim_length = leading_len + (trailing_len - leading_len) * (1.0 - t);
        }

        self.target = .{ x, y };
        self.prev_target = .{ x, y };
    }

    /// Update all corners
    pub fn update(self: *CornerCursorAnimation, dt: f32, cell_width: f32, cell_height: f32) bool {
        if (!self.enabled) return false;

        var animating = false;
        for (&self.corners) |*corner| {
            if (corner.update(dt, self.target, cell_width, cell_height)) {
                animating = true;
            }
        }
        return animating;
    }

    /// Get corner positions for rendering (in pixel coordinates)
    pub fn getCorners(self: *const CornerCursorAnimation) [4][2]f32 {
        return .{
            self.corners[0].current,
            self.corners[1].current,
            self.corners[2].current,
            self.corners[3].current,
        };
    }

    /// Snap all corners to target immediately
    pub fn snap(self: *CornerCursorAnimation, cell_width: f32, cell_height: f32) void {
        for (&self.corners) |*corner| {
            corner.current = .{
                self.target[0] + (corner.relative_pos[0] + 0.5) * cell_width,
                self.target[1] + (corner.relative_pos[1] + 0.5) * cell_height,
            };
            corner.spring_x.reset();
            corner.spring_y.reset();
            corner.prev_dest = corner.current;
        }
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
