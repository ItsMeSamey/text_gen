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
    const keyHashFn = std.array_hash_map.getAutoHashFn([Len]Key, @This());
    pub fn hash(self: @This(), k: kvp) u32 {
      return keyHashFn(self, k.k);
    }
    pub fn eql(_: @This(), a: kvp, b: kvp, _: usize) bool {
      return meta.arrAsUint(a.k) == meta.arrAsUint(b.k);
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

    /// Writes the data to `writer` and deinitializes this object and hence should be only called once
    /// `MinKeyType` tells us what is the minimum possible int size needed for key values
    /// `MinKeyType` = `u8` must be used only for char model
    pub fn write(self: *Self, writer: std.io.AnyWriter, comptime MinKeyType: type) !void {
      const TableKey = meta.TableKey(MinKeyType, Val);
      const TableVal = meta.TableVal(MinKeyType, Val);

      const fullList = self.map.keys();
      defer self.map.deinit();

      std.sort.pdq(kvp, fullList, {}, struct {
        fn function(_: void, lhs: kvp, rhs: kvp) bool {
          return meta.asUint(Len, &lhs.k) < meta.asUint(Len, &rhs.k);
        }
      }.function);

      // Make a list if all the keys
      var list = std.ArrayList(struct { k: [Len-1]Key, v: Val, n: u32 = undefined }).init(self.map.allocator);
      defer list.deinit();

      try list.append(.{
        .k = fullList[0].k[0..Len-1].*,
        .v = fullList[0].v,
      });
      for (fullList) |entry| {
        if (meta.arrAsUint(list.getLast().k) == meta.arrAsUint(entry.k[0..Len-1])) continue;
        try list.append(.{
          .k = entry.k[0..Len-1].*,
          .v = entry.v,
        });
      }

      try MarkovModelStats.init(Len, MinKeyType, Val, defaults.Endian).flush(writer);
      try writer.writeInt(u64, list.items.len * @sizeOf(kvp), defaults.Endian);

      var nextMap = std.AutoHashMap(std.meta.Int(.unsigned, (Len-2) * 8 * @sizeOf(Val)), u32).init(self.map.allocator);
      defer nextMap.deinit();

      // Write keys
      for (list.items, 0..) |entry, index| {
        const postfix = meta.arrAsUint(entry.k[1..][0..Len-2]);

        var mid: u32 = undefined;

        // Get the offset of the next entry in mid
        if (nextMap.get(postfix)) |val| {
          mid = val;
        } else {
          var start: u32 = 0;
          var end: u32 = @intCast(list.items.len);
          while (start < end) {
            mid = start + (end - start) / 2;
            if (meta.arrAsUint(list.items[mid].k[1..][0..Len-2]) < postfix) {
              start = mid + 1;
            } else {
              end = mid;
            }
          }

          try nextMap.put(postfix, mid);
        }

        list.items[index].n = mid;
        try writer.writeStructEndian(TableKey{
          .key = @intCast(entry.k[0]),
          .value = @intCast(index),
          .next = mid,
        }, defaults.Endian);
      }

      // The last (extra) key to make computation easier, see genMarkov.zig's GetMarkovGen.Generator.gen
      try writer.writeStructEndian(TableKey{
        .key = std.math.maxInt(MinKeyType),
        .value = @intCast(list.items.len),
        .next = 0,
      }, defaults.Endian);


      // Write values
      var index: u32 = 0;
      for (fullList) |item| {
        if (meta.arrAsUint(item.k[0..Len-1]) != meta.arrAsUint(list.items[index].k[0..Len-1])) index += 1;

        var start: u32 = list.items[index].n;
        var end: u32 = list.items[index + 1].n;
        var mid: u32 = undefined;
        while (start < end) {
          mid = start + (end - start) / 2;
          if (fullList[mid].k[Len-1] < item.k[Len-1]) {
            start = mid + 1;
          } else if (fullList[mid].k[Len-1] > item.k[Len-1]) {
            end = mid;
          } else {
            break;
          }
        }

        try writer.writeStructEndian(TableVal{
          .val = item.v,
          .subnext = @intCast(mid - start),
        }, defaults.Endian);
      }
    }

    pub fn deinit(self: *Self) void {
      self.map.deinit();
    }
  };
}

test {
  std.testing.refAllDecls(GenBase(2, defaults.CharKey, defaults.Val));
  std.testing.refAllDecls(GenBase(2, defaults.WordKey, defaults.Val));
}

