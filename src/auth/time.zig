/// Time formatting utilities for AWS Signature V4.
const std = @import("std");
const Allocator = std.mem.Allocator;
const fmt = std.fmt;
const time = std.time;

pub const UtcDateTime = struct {
    year: u32,
    month: u8,
    day: u8,
    hour: u8,
    minute: u8,
    second: u8,

    /// Create a UTC date time from the Unix timestamp (in seconds)
    pub fn init(timestamp_secs: i64) UtcDateTime {
        const seconds: u64 = @intCast(timestamp_secs);
        const day_seconds: u64 = @mod(seconds, 86400);
        const epoch_days: u64 = @divFloor(seconds, 86400);
        var days: u32 = @intCast(epoch_days);

        // Calculate year, month, day
        var year: u32 = 1970;
        while (days >= 365) {
            const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);
            const days_in_year = if (is_leap) @as(u32, 366) else @as(u32, 365);
            if (days < days_in_year) break;
            days -= days_in_year;
            year += 1;
        }

        const month_days = [_]u8{ 31, 28, 31, 30, 31, 30, 31, 31, 30, 31, 30, 31 };
        var month: u8 = 1;
        const is_leap = (year % 4 == 0 and year % 100 != 0) or (year % 400 == 0);

        for (month_days, 0..) |days_in_month, i| {
            var adjusted_days = days_in_month;
            if (i == 1 and is_leap) adjusted_days += 1;
            if (days < adjusted_days) break;
            days -= adjusted_days;
            month += 1;
        }

        return .{
            .year = year,
            .month = month,
            .day = @intCast(days + 1),
            .hour = @intCast(@divFloor(day_seconds, 3600)),
            .minute = @intCast(@divFloor(@mod(day_seconds, 3600), 60)),
            .second = @intCast(@mod(day_seconds, 60)),
        };
    }

    pub fn now() UtcDateTime {
        return .init(std.time.timestamp());
    }

    /// Format timestamp in ISO standard YYYY-MM-DD'T'HH:MI:SS'Z'
    pub fn format(self: *const UtcDateTime, alloc: Allocator) ![]const u8 {
        return fmt.allocPrint(
            alloc,
            "{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z",
            .{ self.year, self.month, self.day, self.hour, self.minute, self.second },
        );
    }

    /// Format timestamp as YYYYMMDD for AWS date
    pub fn formatAmzDate(self: *const UtcDateTime, alloc: Allocator) ![]const u8 {
        return fmt.allocPrint(
            alloc,
            "{d:0>4}{d:0>2}{d:0>2}",
            .{ self.year, self.month, self.day },
        );
    }

    /// Format timestamp as YYYYMMDD'T'HHMMSS'Z' for AWS
    pub fn formatAmz(self: *const UtcDateTime, alloc: Allocator) ![]const u8 {
        return fmt.allocPrint(
            alloc,
            "{d:0>4}{d:0>2}{d:0>2}T{d:0>2}{d:0>2}{d:0>2}Z",
            .{ self.year, self.month, self.day, self.hour, self.minute, self.second },
        );
    }

    pub fn jsonStringify(self: *const UtcDateTime, jws: anytype) !void {
        try jws.print(
            "\"{d:0>4}-{d:0>2}-{d:0>2}T{d:0>2}:{d:0>2}:{d:0>2}Z\"",
            .{ self.year, self.month, self.day, self.hour, self.minute, self.second },
        );
    }
};

/// Check if a year is a leap year
fn isLeapYear(year: u16) bool {
    return (year % 4 == 0 and year % 100 != 0) or year % 400 == 0;
}

test "time formatting" {
    const allocator = std.testing.allocator;

    // Test case: 2013-05-24T00:00:00Z (1369353600)
    const timestamp: i64 = 1369353600;

    const dt = UtcDateTime.init(timestamp);
    const datetime = try dt.formatAmz(allocator);
    defer allocator.free(datetime);
    try std.testing.expectEqualStrings("20130524T000000Z", datetime);

    const date = try dt.formatAmzDate(allocator);
    defer allocator.free(date);
    try std.testing.expectEqualStrings("20130524", date);
}

test "leap year" {
    try std.testing.expect(isLeapYear(2000));
    try std.testing.expect(isLeapYear(2004));
    try std.testing.expect(!isLeapYear(2100));
    try std.testing.expect(!isLeapYear(2001));
}
