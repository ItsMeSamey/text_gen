const std = @import("std");

pub fn SizedUint(maxCap: comptime_int) type {
  return std.meta.Int(.unsigned, std.math.log2(maxCap << 1));
}

test SizedUint {
  try std.testing.expect(SizedUint(0) == u0);
  try std.testing.expect(SizedUint(1) == u1);
  try std.testing.expect(SizedUint(2) == u2);
  try std.testing.expect(SizedUint(3) == u2);

  try std.testing.expect(SizedUint(std.math.maxInt(u16)) == u16);
  try std.testing.expect(SizedUint(std.math.maxInt(u16) + 1) == u17);
}

pub fn Uint(comptime len: comptime_int, sliceType: type) type {
  const childSize = @sizeOf(std.meta.Elem(sliceType)) * 8;
  return std.meta.Int(.unsigned, childSize * len);
}

/// Convert a slice of af a given size to uint of appropriate length
pub fn asUint(comptime len: comptime_int, slice: anytype) Uint(len, @TypeOf(slice)) {
  const nonSentinel = @as([]const std.meta.Elem(@TypeOf(slice)), slice);
  return @bitCast(nonSentinel[0..len].*);
}

test asUint {
  try std.testing.expect(asUint(5, "hello") == @as(u40, @bitCast([5]u8{'h', 'e', 'l', 'l', 'o'})));
}
// Convert array to a uint
pub fn arrAsUint(arr: anytype) Uint(arr.len, @TypeOf(arr)) {
  return asUint(arr.len, arr);
}

/// Similar to std.math.compare but is more deneric
pub fn compare(a: anytype, comptime op: std.math.CompareOperator, b: anytype) @TypeOf(a == b) {
  return switch (op) {
    .lt => a < b,
    .lte => a <= b,
    .eq => a == b,
    .neq => a != b,
    .gt => a > b,
    .gte => a >= b,
  };
}

/// Give the negative of an operation
pub fn opposite(comptime op: std.math.CompareOperator) std.math.CompareOperator {
  return switch (op) {
    .lt => .gte,
    .lte => .gt,
    .eq => .neq,
    .neq => .eq,
    .gt => .lte,
    .gte => .lt,
  };
}

test SizedUint {
  try std.testing.expect(SizedUint(0) == u0);
  try std.testing.expect(SizedUint(1) == u1);
  try std.testing.expect(SizedUint(2) == u2);
  try std.testing.expect(SizedUint(3) == u2);

  try std.testing.expect(SizedUint(std.math.maxInt(u16)) == u16);
  try std.testing.expect(SizedUint(std.math.maxInt(u16) + 1) == u17);
}

test asUint {
  try std.testing.expect(asUint(5, "hello") == @as(u40, @bitCast([5]u8{'h', 'e', 'l', 'l', 'o'})));
}

