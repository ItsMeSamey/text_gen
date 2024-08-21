const std = @import("std");

pub fn Uint(comptime len: comptime_int, sliceType: type) type {
  const childSize = @sizeOf(std.meta.Child(sliceType)) * 8;
  return std.meta.Int(.unsigned, childSize * len);
}

/// Convert a slice of af a given size to uint of appropriate length
pub fn asUint(comptime len: comptime_int, slice: anytype) Uint(len, @TypeOf(slice)) {
  return @bitCast(slice[0..len].*);
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

