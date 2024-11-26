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

pub fn TableChain(Key: type, Val: type) type {
  _ = Key;
  return packed struct {
    /// offset offset to some TableKey of this chain
    offset: u32,
    /// Probability similar to TableVal.val
    val: Val,
  };
}

pub fn TableKey(Key: type, Val: type) type {
  _ = Val;
  return packed struct {
    /// Key (the last one) that should be next
    key: Key,
    /// offset to values in `vals` table
    value: u32,
    /// offset to the first entry of what would be the next value
    next: u32,
  };
}

pub fn TableVal(Key: type, Val: type) type {
  return packed struct {
    /// suboffset to the next entry that should be, actual offset to next = Keys.next + Vals.subnext
    subnext: Key,
    /// a kind probability that this value should be considered
    /// NOTE: this is not the actual `probability`, it's actual probability + val of prev entry
    /// eg: say we have 3 Vals for some key with with actual probability = {.3, .5, .2}, Vals = { .3, .8, 1} (the last value is always 1)
    /// this is done to make random selection easy and less computationally expensive
    val: Val,
  };
}

/// An interface for swapping endianness of anything
pub fn swapEndianness(ptr: anytype) void {
  const S = @typeInfo(@TypeOf(ptr)).pointer.child;
  switch (@typeInfo(S)) {
    // -- Unhandled types --
    // optional: Optional,
    // @"union": Union,
    // frame: Frame,
    // @"anyframe": AnyFrame,
    // vector: Vector,
    // @"opaque": Opaque,

    .type, .void, .bool, .noreturn, .undefined, .null, .error_union, .error_set, .@"fn", .enum_literal => {},
    .int, .comptime_float, .comptime_int => {
      ptr.* = @byteSwap(ptr.*);
    },
    .float => |float_info| {
      ptr.* = @bitCast(@byteSwap(@as(std.meta.Int(.unsigned, float_info.bits), @bitCast(ptr.*))));
    },
    .pointer => |ptr_info| {
      switch (ptr_info.size) {
        .Slice => {
          for (ptr) |*item| swapEndianness(item);
        },
        else => @compileError("swapEndianness unexpected child to pointer type `" ++ @typeName(S) ++ "`"),
      }
    },
    .array => {
      for (ptr) |*item| swapEndianness(item);
    },
    .@"struct" => {
      inline for (std.meta.fields(S)) |f| {
        switch (@typeInfo(f.type)) {
          .@"struct" => |struct_info| if (struct_info.backing_integer) |Int| {
            @field(ptr, f.name) = @bitCast(@byteSwap(@as(Int, @bitCast(@field(ptr, f.name)))));
          } else {
            swapEndianness(&@field(ptr, f.name));
          },
        }
      }
    },
    .@"enum" => {
      ptr.* = @enumFromInt(@byteSwap(@intFromEnum(ptr.*)));
    },
    else => @compileError("swapEndianness unexpected type `" ++ @typeName(S) ++ "` found"),
  }
}

