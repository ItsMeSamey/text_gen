const std = @import("std");

/// Get the minimum integer type that can hold value atleast upto max_cap
pub fn SizedUint(max_cap: comptime_int) type {
  return std.meta.Int(.unsigned, std.math.log2(max_cap << 1));
}

test SizedUint {
  try std.testing.expect(SizedUint(0) == u0);
  try std.testing.expect(SizedUint(1) == u1);
  try std.testing.expect(SizedUint(2) == u2);
  try std.testing.expect(SizedUint(3) == u2);

  try std.testing.expect(SizedUint(std.math.maxInt(u16)) == u16);
  try std.testing.expect(SizedUint(std.math.maxInt(u16) + 1) == u17);
}

/// Gives the uint type that could hold the given value inside it
pub fn Uint(len: comptime_int, sliceType: type) type {
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
  const nonSentinel = @as(*const [arr.len]std.meta.Elem(@TypeOf(arr)), if (@typeInfo(@TypeOf(arr)) == .pointer) arr else &arr);
  return @bitCast(nonSentinel.*);
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

/// Table key struct
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

/// Table val struct
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

const native_endianness = @import("builtin").cpu.arch.endian();

///
pub fn writePackedStructEndian(writer: std.io.AnyWriter, value: anytype, comptime endian: std.builtin.Endian) !void {
  var copy = value;
  if (native_endianness != endian) std.mem.byteSwapAllFields(@TypeOf(copy), &copy);
  const size = (@bitSizeOf(@TypeOf(copy)) + 7) >> 3;
  const bytes = std.mem.asBytes(&copy)[0..size];
  return try writer.writeAll(bytes);
}

/// Read the packed struct from bytes
pub fn readPackedStructEndian(comptime T: type, ptr: *const [(@bitSizeOf(T) + 7) >> 3]u8, comptime endian: std.builtin.Endian) T {
  const size = (@bitSizeOf(T) + 7) >> 3;
  var oval: T = undefined;
  @memcpy(std.mem.asBytes(&oval)[0..size], ptr[0..]);
  @memset(std.mem.asBytes(&oval)[size..], 0);
  if (native_endianness != endian) std.mem.byteSwapAllFields(@TypeOf(oval), &oval);
  return oval;
}

