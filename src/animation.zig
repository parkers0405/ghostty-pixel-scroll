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
        // Neovide convention: delta = target - current, spring animates toward 0
        self.spring.setTarget(x - self.current_x, y - self.current_y);
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

        // Current position = target - spring offset
        // As spring.position approaches 0, current approaches target
        const offset = self.spring.getOffset();
        self.current_x = self.target_x - offset.x;
        self.current_y = self.target_y - offset.y;

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
/// Neovide-style stretchy cursor animation with 4 independently animated corners.
/// Front corners (in direction of movement) animate faster than back corners,
/// creating a stretchy trail effect. Exactly matches Neovide's implementation.
pub const CornerCursorAnimation = struct {
    /// Corner positions relative to cursor center (-0.5 to 0.5 for each axis)
    /// Order: top-left, top-right, bottom-right, bottom-left (matches Neovide)
    const STANDARD_CORNERS: [4][2]f32 = .{
        .{ -0.5, -0.5 }, // top-left
        .{ 0.5, -0.5 }, // top-right
        .{ 0.5, 0.5 }, // bottom-right
        .{ -0.5, 0.5 }, // bottom-left
    };

    /// Corner state - matches Neovide's Corner struct
    const Corner = struct {
        /// Current pixel position
        current_position: [2]f32 = .{ 0, 0 },
        /// Relative position within cell (-0.5 to 0.5)
        relative_position: [2]f32 = .{ 0, 0 },
        /// Previous destination (to detect changes)
        previous_destination: [2]f32 = .{ -1000, -1000 },
        /// Spring for X animation
        animation_x: Spring = .{},
        /// Spring for Y animation
        animation_y: Spring = .{},
        /// Animation length for this corner (varies based on rank)
        animation_length: f32 = 0.15,

        /// Get the destination position for this corner given cursor center destination
        fn getDestination(self: *const Corner, center_dest: [2]f32, cursor_width: f32, cursor_height: f32) [2]f32 {
            return .{
                center_dest[0] + self.relative_position[0] * cursor_width,
                center_dest[1] + self.relative_position[1] * cursor_height,
            };
        }

        /// Calculate how aligned this corner is with travel direction (for ranking)
        fn calculateDirectionAlignment(self: *const Corner, center_dest: [2]f32, cursor_width: f32, cursor_height: f32) f32 {
            const corner_dest = self.getDestination(center_dest, cursor_width, cursor_height);

            // Normalize relative position to get corner direction from center
            const rel_len = @sqrt(self.relative_position[0] * self.relative_position[0] +
                self.relative_position[1] * self.relative_position[1]);
            const corner_dir: [2]f32 = if (rel_len > 0.001)
                .{ self.relative_position[0] / rel_len, self.relative_position[1] / rel_len }
            else
                .{ 0, 0 };

            // Travel direction from current to destination
            const dx = corner_dest[0] - self.current_position[0];
            const dy = corner_dest[1] - self.current_position[1];
            const travel_len = @sqrt(dx * dx + dy * dy);
            const travel_dir: [2]f32 = if (travel_len > 0.001)
                .{ dx / travel_len, dy / travel_len }
            else
                .{ 0, 0 };

            // Dot product gives alignment (-1 to 1)
            return travel_dir[0] * corner_dir[0] + travel_dir[1] * corner_dir[1];
        }

        /// Update corner animation
        fn update(self: *Corner, dt: f32, center_dest: [2]f32, cursor_width: f32, cursor_height: f32, immediate: bool) bool {
            const corner_dest = self.getDestination(center_dest, cursor_width, cursor_height);

            // Immediate movement - snap to destination
            if (immediate) {
                self.current_position = corner_dest;
                self.previous_destination = corner_dest;
                self.animation_x.reset();
                self.animation_y.reset();
                return false;
            }

            // Check if destination changed - reset spring to new delta
            if (corner_dest[0] != self.previous_destination[0] or corner_dest[1] != self.previous_destination[1]) {
                // Set spring to animate from current to new destination
                // Neovide convention: delta = dest - current, then current = dest - spring.position
                // Spring starts at delta and animates toward 0
                self.animation_x.position = corner_dest[0] - self.current_position[0];
                self.animation_y.position = corner_dest[1] - self.current_position[1];
                self.previous_destination = corner_dest;
            }

            // Update springs with critically damped response (zeta = 1.0)
            var animating = self.animation_x.update(dt, self.animation_length, 1.0);
            animating = self.animation_y.update(dt, self.animation_length, 1.0) or animating;

            // Current position = destination - spring offset (spring starts at delta, animates toward 0)
            // As spring.position approaches 0, current_position approaches destination
            self.current_position[0] = corner_dest[0] - self.animation_x.position;
            self.current_position[1] = corner_dest[1] - self.animation_y.position;

            return animating;
        }

        /// Set animation length based on rank (Neovide's jump logic)
        fn setAnimationLengthByRank(self: *Corner, rank: usize, leading: f32, trailing: f32) void {
            self.animation_length = switch (rank) {
                // Leading corners (rank 2-3) move fastest
                2, 3 => leading,
                // Middle corner (rank 1) moves at average speed
                1 => (leading + trailing) / 2.0,
                // Trailing corner (rank 0) moves slowest
                0 => trailing,
                else => trailing,
            };
        }
    };

    /// The 4 corners
    corners: [4]Corner = undefined,
    /// Target position (CENTER of cursor in pixels) - Neovide uses center, not top-left
    destination: [2]f32 = .{ 0, 0 },
    /// Previous cursor position for detecting jumps
    previous_destination: [2]f32 = .{ -1000, -1000 },
    /// Whether we just jumped to a new position
    jumped: bool = false,

    // Neovide-style settings (tuned for less extreme stretch)
    /// Base animation length (0.10 seconds - slightly faster than Neovide's 0.15)
    const ANIMATION_LENGTH: f32 = 0.10;
    /// Short animation for typing (0.04 seconds)
    const SHORT_ANIMATION_LENGTH: f32 = 0.04;
    /// Trail size (0.8 = moderate trail, less extreme than Neovide's 1.0)
    const TRAIL_SIZE: f32 = 0.8;

    pub fn init() CornerCursorAnimation {
        var self = CornerCursorAnimation{};
        for (0..4) |i| {
            self.corners[i] = Corner{
                .relative_position = STANDARD_CORNERS[i],
            };
        }
        return self;
    }

    /// Update corner relative positions based on cursor shape
    /// This transforms corners for vertical bar (insert mode) or horizontal underline (replace mode)
    pub fn setCursorShape(self: *CornerCursorAnimation, shape: CursorShape, cell_percentage: f32) void {
        for (0..4) |i| {
            const x = STANDARD_CORNERS[i][0];
            const y = STANDARD_CORNERS[i][1];

            self.corners[i].relative_position = switch (shape) {
                .block => .{ x, y },
                // Transform x so right side is at cell_percentage position
                // For 20% bar: x=-0.5 stays at -0.5, x=0.5 becomes -0.3 (thin bar on left)
                .vertical => .{ (x + 0.5) * cell_percentage - 0.5, y },
                // Transform y so horizontal bar is at bottom with cell_percentage height
                .horizontal => .{ x, -((-y + 0.5) * cell_percentage - 0.5) },
            };
        }
    }

    pub const CursorShape = enum {
        block,
        vertical,
        horizontal,
    };

    /// Set new target position (called when cursor moves)
    /// x, y = top-left of cursor cell in pixels
    pub fn setTarget(self: *CornerCursorAnimation, x: f32, y: f32, cell_width: f32, cell_height: f32) void {
        // Convert to center position (Neovide uses center for destination)
        const center_x = x + cell_width * 0.5;
        const center_y = y + cell_height * 0.5;

        // On first call, snap immediately
        if (self.previous_destination[0] < -500) {
            self.snap(x, y, cell_width, cell_height);
            return;
        }

        self.destination = .{ center_x, center_y };
        self.jumped = true;
    }

    /// Update animation - call this every frame
    /// Returns true if still animating
    pub fn update(self: *CornerCursorAnimation, dt: f32, cell_width: f32, cell_height: f32) bool {
        // Handle jump - calculate ranks and set animation lengths
        if (self.jumped) {
            self.handleJump(cell_width, cell_height);
            self.jumped = false;
        }

        var animating = false;
        for (&self.corners) |*corner| {
            if (corner.update(dt, self.destination, cell_width, cell_height, false)) {
                animating = true;
            }
        }
        return animating;
    }

    /// Handle a cursor jump - calculate corner ranks and animation lengths
    fn handleJump(self: *CornerCursorAnimation, cell_width: f32, cell_height: f32) void {
        // Calculate direction alignment for each corner
        var alignments: [4]f32 = undefined;
        for (0..4) |i| {
            alignments[i] = self.corners[i].calculateDirectionAlignment(self.destination, cell_width, cell_height);
        }

        // Sort corners by alignment to get ranks (Neovide sorts then re-sorts by id)
        // We'll compute ranks directly: count how many corners have lower alignment
        var ranks: [4]usize = undefined;
        for (0..4) |i| {
            var rank: usize = 0;
            for (0..4) |j| {
                if (i != j) {
                    // Lower alignment = lower rank (trailing)
                    if (alignments[j] < alignments[i]) {
                        rank += 1;
                    } else if (alignments[j] == alignments[i] and j < i) {
                        // Tie-breaker: lower index = lower rank
                        rank += 1;
                    }
                }
            }
            ranks[i] = rank;
        }

        // Calculate jump vector to determine if this is a small jump (typing)
        const jump_x = (self.destination[0] - self.previous_destination[0]) / cell_width;
        const jump_y = (self.destination[1] - self.previous_destination[1]) / cell_height;
        const is_small_jump = @abs(jump_x) <= 2.001 and @abs(jump_y) < 0.001;

        // Calculate leading and trailing animation times
        const base_length = if (is_small_jump)
            @min(ANIMATION_LENGTH, SHORT_ANIMATION_LENGTH)
        else
            ANIMATION_LENGTH;

        // With TRAIL_SIZE = 1.0: leading = 0, so leading corners jump instantly!
        const leading = base_length * (1.0 - TRAIL_SIZE);
        const trailing = base_length;

        // Set animation length for each corner based on rank
        for (0..4) |i| {
            self.corners[i].setAnimationLengthByRank(ranks[i], leading, trailing);
        }

        self.previous_destination = self.destination;
    }

    /// Get corner positions for rendering (in pixel coordinates)
    /// Returns: [TL, TR, BR, BL] corner positions
    pub fn getCorners(self: *const CornerCursorAnimation) [4][2]f32 {
        return .{
            self.corners[0].current_position,
            self.corners[1].current_position,
            self.corners[2].current_position,
            self.corners[3].current_position,
        };
    }

    /// Snap all corners to a specific position immediately (no animation)
    /// x, y = top-left of cursor cell in pixels
    pub fn snap(self: *CornerCursorAnimation, x: f32, y: f32, cell_width: f32, cell_height: f32) void {
        const center_x = x + cell_width * 0.5;
        const center_y = y + cell_height * 0.5;
        self.destination = .{ center_x, center_y };
        self.previous_destination = .{ center_x, center_y };
        self.jumped = false;

        for (&self.corners) |*corner| {
            corner.current_position = corner.getDestination(self.destination, cell_width, cell_height);
            corner.previous_destination = corner.current_position;
            corner.animation_x.reset();
            corner.animation_y.reset();
        }
    }

    /// Reset animation state (snap to current destination)
    pub fn reset(self: *CornerCursorAnimation, cell_width: f32, cell_height: f32) void {
        const x = self.destination[0] - cell_width * 0.5;
        const y = self.destination[1] - cell_height * 0.5;
        self.snap(x, y, cell_width, cell_height);
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
