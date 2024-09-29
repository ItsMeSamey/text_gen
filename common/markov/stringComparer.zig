const std = @import("std");
const meta = @import("meta.zig");
const asUint = meta.asUint;
const compare = meta.compare;
const opposite = meta.opposite;

/// This is a faster way to do compares. (in my testing)
///   This is NOT the same as std,math.order.
///   This does not guarantee consistency after concatenation.
///     i.e. even if `getCompareBytes(.lt)(a, b)` is true, `getCompareBytes(.lt)(x++a,x++b)` may be false
pub fn getCompareBytes(comptime op: std.math.CompareOperator) fn ([]const u8, []const u8) bool {
  const simdVectorLength = if (op == .eq or op == .neq) std.simd.suggestVectorLength(u8) else null;
  const Scan = struct {
    const Chunk = if (simdVectorLength) |length| @Vector(length, u8) else usize;
    const size = @sizeOf(Chunk);

    fn is(a: anytype, b: @TypeOf(a)) bool {
      return switch (@typeInfo(@TypeOf(a))) {
        .Vector => @reduce(.And, compare(a, .eq, b)),
        else => compare(a, op, b),
      };
    }
  };

  const jtSize = if (op == .eq or op == .neq) 16 else Scan.size;
  const scope = struct {
    fn function(a: []const u8, b: []const u8) bool {
      if (a.len != b.len) return compare(a.len, op, b.len);
      return if (a.len < jtSize) beforeSize(a, b) else afterSize(a, b);
    }

    /// The main equating function
    fn beforeSize(a: []const u8, b: []const u8) bool {
      return switch (a.len) {
        0  => compare(0, op, 0),
        inline 1...jtSize => |len| compare(asUint(len, a), op, asUint(len, b)),
        else => unreachable,
      };
    }

    /// To continue comparing for lengths beyond jtLen
    fn afterSize(a: []const u8, b: []const u8) bool {
      if (op == .eq or op == .neq) {
        inline for (1..6) |s| {
          const n = 16 << s;
          const V = @Vector(n / 2, u8);
          if (n <= Scan.size and a.len <= n) {
            const start = Scan.is(@as(V, a[0 .. n / 2].*), @as(V, b[0 .. n / 2].*));
            const end = Scan.is(@as(V, a[a.len - n / 2 ..][0 .. n / 2].*), @as(V, b[a.len - n / 2 ..][0 .. n / 2].*));
            // std.debug.print("start: {}, end: {}\n", .{start, end});
            return if (op == .eq) start and end else start or end;
          }
        }
      }

      // Compare inputs in chunks at a time (excluding the last chunk).
      for (0..(a.len - 1) / Scan.size) |i| {
        const a_chunk: Scan.Chunk = @bitCast(a[i * Scan.size ..][0..Scan.size].*);
        const b_chunk: Scan.Chunk = @bitCast(b[i * Scan.size ..][0..Scan.size].*);
        if (op == .eq) { if (!Scan.is(a_chunk, b_chunk)) return false;}
        else { if (Scan.is(a_chunk, b_chunk)) return true; }
      }

      // Compare the last chunk using an overlapping read (similar to the previous size strategies).
      const last_a_chunk: Scan.Chunk = @bitCast(a[a.len - Scan.size ..][0..Scan.size].*);
      const last_b_chunk: Scan.Chunk = @bitCast(b[a.len - Scan.size ..][0..Scan.size].*);
      return Scan.is(last_a_chunk, last_b_chunk);
    }
  };

  return scope.function;
}

pub const strEq = getCompareBytes(.eq);
/// For sorting purpose only
/// only `Lt(a, b) == !Lt(b, a)` is guaranteed,
///   eg. if `Lt(a, b) == true`, a < b is NOT guaranteed
pub const strLt = getCompareBytes(.lt);

test {
  try std.testing.expect(strEq("123", "123"));
  try std.testing.expect(strLt("14", "23") or strLt("23", "14"));

  const pre = " " ** 16;
  try std.testing.expect(strEq(pre ++ "123", pre ++ "123"));
  try std.testing.expect(strLt(pre ++ "23", pre ++ "14") or strLt(pre ++ "14", pre ++ "23"));
}

