const std = @import("std");
const meta = @import("meta.zig");

const MarkovModelStats = @import("markovStats.zig").ModelStats;
const defaults = @import("defaults.zig");

/// A base onject to store the frequency of occurrence a sequence
/// if `Key` is u8, assumes a char model
/// The Val type here is used only during model creation
pub fn GenBase(Len: comptime_int, Key: type, Val: type) type {
  // Validate inputs
  _ = MarkovModelStats.init(Len, Key, Val, defaults.Endian);

  // Done this way so we can easily sort the keys array without copying
  const kvp = struct { k: [Len]Key, v: Val };
  const MarkovMap = std.ArrayHashMap(kvp, void, struct {
    pub fn hash(_: @This(), k: kvp) u64 {
      return std.hash_map.getAutoHashFn([Len]Key, @This())(k.k);
    }
    pub fn eql(_: @This(), a: kvp, b: kvp) bool {
      return meta.asUint(Len, a.k) == meta.asUint(Len, b.k);
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

    /// Writes the data to `writer` does *NOT* deinitialize anything
    /// `MinKeyType` tells us what is the minimum possible int size needed for key values
    /// `MinKeyType` = `u8` must be used only for char model
    ///
    /// The model is stored into the file (writer) as follows
    /// 1 * [ model stats ]; <- header (type = MarkovModelStats)
    /// unknown * [ <- section(s)
    ///   (Len-2) * MinKeyType <-
    /// ];
    pub fn write(self: *Self, writer: std.io.AnyWriter, comptime MinKeyType: type) !void {
      const list = self.map.keys();
      std.sort.pdq(kvp, list, {}, struct {
        fn function(_: void, lhs: kvp, rhs: kvp) bool {
          return meta.asUint(Len, &lhs.k) < meta.asUint(Len, &rhs.k);
        }
      }.function);

      try MarkovModelStats.init(Len, MinKeyType, Val, defaults.Endian).flush(writer);
      try writer.writeInt(u64, list.len * @sizeOf(std.meta.Child(list.ptr)), defaults.Endian);

      var index: usize = 0;
      while (index != list.len) {
        const prefix = list[index].k[0..Len-1];
        inline for (prefix) |item| try writer.writeInt(MinKeyType, item, defaults.Endian);

        try writer.writeInt(Val, std.sort.partitionPoint(kvp, list, meta.arrAsUint(prefix), struct {
          fn partitionPointFn(target: meta.Uint(Len-1, Val), val: kvp) bool {
            return meta.asUint(Len-1, &val.k) < target;
          }
        }.partitionPointFn));

        var nextIndex = index;
        while (nextIndex != list.len and meta.arrAsUint(list[nextIndex].k[0..Len-1]) == meta.arrAsUint(prefix)) nextIndex += 1;
        try writer.writeInt(MinKeyType, nextIndex, defaults.Endian);

        for (index..nextIndex) |i| {
          try writer.writeInt(MinKeyType, list[i].k[Len-1], defaults.Endian);
          try writer.writeInt(Val, @bitCast(list[i].v), defaults.Endian);
        }
        index = nextIndex;
      }
    }

    /// Free everything owned by this (Base) object
    pub fn deinit(self: *Self) void {
      self.map.deinit();
    }
  };
}

test {
  std.testing.refAllDecls(GenBase(2, defaults.CharKey, defaults.Val));
  std.testing.refAllDecls(GenBase(2, defaults.WordKey, defaults.Val));
}

