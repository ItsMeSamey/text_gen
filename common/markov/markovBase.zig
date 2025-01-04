const std = @import("std");
const builtin = @import("builtin");
const meta = @import("meta.zig");

const MarkovModelStats = @import("markovStats.zig").ModelStats;
const defaults = @import("defaults.zig");

/// A base onject to store the frequency of occurrence a sequence
/// if `Key` is u8, assumes a char model
/// The Val type here is used only during model creation
pub fn GenBase(Len: comptime_int, Key: type, Val: type) type {
  // Validate inputs
  _ = MarkovModelStats.init(Key, Val, defaults.Endian);

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
      const result = try self.map.getOrPut(.{ .k = key, .v = 1 });
      if (result.found_existing) result.key_ptr.v += 1;
    }

    /// Writes the data to `writer` and deinitializes this object and hence should be only called once
    /// `MinKeyType` tells us what is the minimum possible int size needed for key values
    /// `MinKeyType` = `u8` must be used only for char model
    pub fn write(self: *Self, writer: std.io.AnyWriter, comptime MinKeyType: type) !void {
      try MarkovModelStats.init(MinKeyType, Val, defaults.Endian).flush(writer);

      const TableKey = meta.TableKey(MinKeyType, Val);
      const TableVal = meta.TableVal(MinKeyType, Val);

      const fullList = self.map.keys();

      std.sort.pdq(kvp, fullList, {}, struct {
        fn lessThanFn(_: void, lhs: kvp, rhs: kvp) bool {
          inline for (0..Len-1) |i| if (lhs.k[i] != rhs.k[i]) return lhs.k[i] < rhs.k[i];
          return false;
        }
      }.lessThanFn);

      // Make a list if all the keys
      var list = std.ArrayList(struct { key: [Len-1]Key, from: u32, next: u32 = undefined }).init(self.map.allocator);
      defer list.deinit();

      try list.append(.{
        .key = fullList[0].k[0..Len-1].*,
        .from = 0,
      });
      for (fullList, 0..) |entry, from| {
        if (meta.arrAsUint(list.getLast().key) == meta.arrAsUint(entry.k[0..Len-1])) continue;
        try list.append(.{
          .key = entry.k[0..Len-1].*,
          .from = @intCast(from),
        });
      }

      // Write keys
      for (list.items) |*entry| {
        var mid: u32 = undefined;

        // Get the offset of the next entry in mid
        if (Len == 2) {
          mid = 0;
        } else {
          var start: u32 = 0;
          var end: u32 = @intCast(list.items.len);
          while (start < end) {
            mid = start + (end - start) / 2;
            if (std.mem.order(Key, entry.key[1..], list.items[mid].key[0..Len-2]) == .gt) {
              start = mid + 1;
            } else {
              end = mid;
            }
          }

          // Partition point uses start/low instead of mid
          mid = start;

          if (builtin.mode == .Debug and mid < list.items.len and !std.mem.eql(Key, entry.key[1..], list.items[mid].key[0..Len-2])) {
            std.debug.print("Partition point: {d}\n", .{mid});
            std.debug.print("entry: {}, next_entry: {}", .{ entry.*, list.items[mid] });
            unreachable;
          }
        }

        entry.next = mid;
        try writer.writeStructEndian(TableKey{
          .key = @intCast(entry.key[0]),
          .value = @intCast(entry.from),
          .next = mid,
        }, defaults.Endian);
      }

      // The last (extra) key to make computation easier, see genMarkov.zig's GetMarkovGen.Generator.gen
      try writer.writeStructEndian(TableKey{
        .key = std.math.maxInt(MinKeyType), // this is never used so it may be undefined, but that triggers ub protection
        .value = @intCast(fullList.len),
        .next = 0,
      }, defaults.Endian);

      // Write keys length (+1 for the extra entry at the end)
      try writer.writeInt(u64, (list.items.len + 1) * @sizeOf(TableKey), defaults.Endian);

      // Write values
      var index: u32 = 0;
      var val: Val = 0;
      for (fullList) |item| {
        if (meta.arrAsUint(item.k[0..Len-1]) != meta.arrAsUint(list.items[index].key)) {
          index += 1;
          val = 0;
          std.debug.assert(index < list.items.len);
          std.debug.assert(meta.arrAsUint(item.k[0..Len-1]) == meta.arrAsUint(list.items[index].key));
        }

        var mid: u32 = undefined;
        var start: u32 = list.items[index].next;
        var end: u32 = @intCast(list.items.len);
        while (start < end) {
          mid = start + (end - start) / 2;
          switch (std.mem.order(Key, list.items[mid].key[0..], item.k[1..])) {
            .lt => start = mid + 1,
            .gt => end = mid,
            .eq => break,
          }
        }

        if (builtin.mode == .Debug and !std.mem.eql(Key, item.k[1..], list.items[mid].key[0..])) {
          std.debug.print("Expected: {}\n", .{ item });
          std.debug.print("Start: {}\n", .{ list.items[list.items[index].next] });
          std.debug.print("Mid: {}\n", .{ list.items[mid] });
          unreachable;
        }

        val += item.v;
        try writer.writeStructEndian(TableVal{
          .val = val,
          .subnext = @intCast(mid - list.items[index].next),
        }, defaults.Endian);
      }

      try writer.writeInt(u64, (fullList.len) * @sizeOf(TableVal), defaults.Endian);
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

