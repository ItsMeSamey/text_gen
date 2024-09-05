const std = @import("std");
const meta = @import("meta.zig");

/// The stats struct
const MarkovModelStats = @import("markovStats.zig").ModelStats;

/// What Endianness is used for the files while storing
const Endianness = @import("defaults.zig").Endian;

/// A stupidly simple way to make a hash map from integer key values
fn StupidHashMap(K: type, V: type) type {
  return std.HashMap(K, V, struct {
    /// Simple hash function that xors all the things
    pub fn hash(_: @This(), a: anytype) u64 {
      @setEvalBranchQuota(1000_000);
      if (64 <= @sizeOf(K)) {
        return a;
      } else {
        const nextType = std.meta.Int(.unsigned, @bitSizeOf(K) - 64);
        const bits = @as([@sizeOf(K)]u8, @bitCast(a));
        return @as(u64, @bitCast(bits[0..8])) ^ hash(@This(){}, @as(nextType, bits[8..@sizeOf(K)]));
      }
    }

    pub fn eql (_: @This(), a: K, b: K) bool {
      return a == b;
    }
  }, std.hash_map.default_max_load_percentage);
}

/// A base onject to store the frequency of occurrence a sequence
/// if `Key` is u8, assumes a char markov mode
pub fn GenBase(Len: comptime_int, Key: type, Val: type) type {
  comptime {
    std.debug.assert(Len > 1);

    std.debug.assert(@typeInfo(Key).Int.signedness == .unsigned);
    std.debug.assert(@typeInfo(Key).Int.bits <= std.math.maxInt(u8));

    std.debug.assert(@typeInfo(Val).Int.signedness == .unsigned);
    std.debug.assert(@typeInfo(Val).Int.bits <= std.math.maxInt(u8));
  } 

  const kvp = struct { k: [Len]Key, v: Val };
  const MarkovMap = std.ArrayHashMap(kvp, void, struct {
    pub fn hash(_: @This(), k: kvp) u64 {
      return std.hash_map.getAutoHashFn([Len]Key, @This())(k.k);
    }
    pub fn eql(_: @This(), a: kvp, b: kvp) bool {
      return meta.asUint(Len, a) == meta.asUint(Len, b);
    }
  }, @sizeOf([Len]Key) <= std.simd.suggestVectorLength(u8) orelse @sizeOf(usize));
  return struct {
    /// Count of The markove chain 
    map: MarkovMap,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
      return .{
        .map = MarkovMap.init(allocator),
      };
    }

    /// Increment the value for encountered key
    pub fn increment(self: *Self, key: [Len]Key) !void {
      const result = try self.map.getOrPut(.{ .k = key, .v = 0 });
      if (result.found_existing) result.key_ptr.v += 1;
    }

    /// Convert the `self.map` to a sorted array. `self.map` may *NOT* be used after this point
    fn SortedList(self: *Self) []kvp {
      const list = self.map.unmanaged.keys();

      std.sort.pdq(kvp, list, {}, struct {
        pub fn function(_: void, lhs: kvp, rhs: kvp) bool { 
          return meta.asUint(Len, &lhs.k) < meta.asUint(Len, &rhs.k);
        }
      }.function);
      return list;
    }

    /// Writes the data to `writer` does *NOT* deinitialize anything
    /// `parentLen` is always 255 for char, and length of word list for words
    pub fn flush(self: *Self, writer: std.io.AnyWriter, parentLen: usize) !void {
      const list = self.SortedList();
      inline for (0..8) |intLen| {
        const intType = std.meta.Int(.unsigned, (intLen+1)*8);
        if (std.math.maxInt(intType) >= parentLen) {

          try writer.writeStructEndian(MarkovModelStats{
            .entriesLen = list.len,
            .modelLen = Len,
            .keyLen = @typeInfo(intType).Int.bits,
            .valLen = @typeInfo(Val).Int.bits,
            .modelType = if (Key == u8) .char else .word,
            .endian = Endianness,
          }, Endianness);
          for (list) |entry| {
            inline for (0..Len) |i| {
              try writer.writeInt(Key, entry.k[i], Endianness);
            }
            try writer.writeInt(Val, entry.v, Endianness);
          }
          return;

        }
      }
      unreachable;
    }

    /// Free everything owned by this (Base) object
    pub fn deinit(self: *Self) void {
      self.map.deinit();
    }
  };
}

const BaseU8 = GenBase(2, u8, u32);
const BaseU32 = GenBase(2, u32, u32);

test {
  var baseU8 = BaseU8.init(std.testing.allocator);
  try baseU8.flush(std.io.null_writer.any(), 0xff);

  var baseU32 = BaseU32.init(std.testing.allocator);
  try baseU32.flush(std.io.null_writer.any(), 0xffff);
}

