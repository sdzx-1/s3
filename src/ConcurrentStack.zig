// SPDX-FileCopyrightText: 2025 Lukáš Lalinský
// SPDX-License-Identifier: MIT

//! Generic simple singly-linked stack (LIFO) for single-threaded use.
//!
//! Provides O(1) push and pop operations.
//!
//! Usage:
//! ```zig
//! const MyNode = struct {
//!     next: ?*MyNode = null,
//!     in_list: if (std.debug.runtime_safety) bool else void = if (std.debug.runtime_safety) false else {},
//!     data: i32,
//! };
//! var stack: SimpleStack(MyNode) = .{};
//! ```
//! Generic lock-free intrusive stack for cross-thread communication.
//!
//! Uses atomic compare-and-swap for thread-safe push operations.
//! PopAll atomically drains the entire stack and returns items in LIFO order.
//!
//! T must be a struct type with a `next` field of type ?*T.
//!
const std = @import("std");
const builtin = @import("builtin");

/// Generic simple LIFO stack.
/// T must be a struct type with `next` field of type ?*T.
/// In debug mode, the struct must also have an `in_list` field of type bool; void in release.
pub fn SimpleStack(comptime T: type) type {
    return struct {
        const Self = @This();

        head: ?*T = null,

        pub fn push(self: *Self, item: *T) void {
            if (std.debug.runtime_safety) {
                std.debug.assert(!item.in_list);
                item.in_list = true;
            }
            item.next = self.head;
            self.head = item;
        }

        pub fn pop(self: *Self) ?*T {
            const head = self.head orelse return null;
            if (std.debug.runtime_safety) {
                head.in_list = false;
            }
            self.head = head.next;
            head.next = null;
            return head;
        }

        /// Move all items from other stack to this stack (prepends).
        pub fn prependByMoving(self: *Self, other: *Self) void {
            const other_head = other.head orelse return;

            // Find tail of other stack
            var tail = other_head;
            while (tail.next) |next| {
                tail = next;
            }

            // Link tail to our current head
            tail.next = self.head;
            self.head = other_head;

            other.head = null;
        }
    };
}

/// Generic concurrent LIFO stack.
/// T must be a struct type with `next` field of type ?*T.
pub fn ConcurrentStack(comptime T: type) type {
    return struct {
        const Self = @This();

        head: std.atomic.Value(?*T) = std.atomic.Value(?*T).init(null),

        /// Push an item onto the stack. Thread-safe, can be called from any thread.
        pub fn push(self: *Self, item: *T) void {
            while (true) {
                const current_head = self.head.load(.acquire);
                item.next = current_head;

                // Try to swing head to new item
                if (self.head.cmpxchgWeak(
                    current_head,
                    item,
                    .release,
                    .acquire,
                ) == null) {
                    return; // Success!
                }
                // CAS failed, retry
            }
        }

        /// Atomically drain all items from the stack.
        /// Returns a SimpleStack containing all drained items (LIFO order).
        pub fn popAll(self: *Self) SimpleStack(T) {
            const head = self.head.swap(null, .acq_rel);
            return SimpleStack(T){ .head = head };
        }
    };
}
