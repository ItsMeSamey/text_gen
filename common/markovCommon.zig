const std = @import("std");

const GenCyclicList = @import("cyclicList.zig").GenCyclicList;
const DataArrayList = std.ArrayList(struct { data: []const u8, allocator: std.mem.Allocator, });

const strEq = @import("stringComparer.zig").strEq;
const strHash = std.hash_map.hashString;
const asUint = @import("meta.zig").asUint;


/// Genetate all the types you will need for the markov generation
fn GenHashMap(Len: comptime_int, Key: type) type {
  comptime std.debug.assert(Len > 1);

  const K = [Len]Key;
  const V = u32;
  const HashMapCtx = switch(Key) {
    u8 => struct {
      /// Different Strategy as length is comptime known.
      pub fn eql(_: @This(), a: K, b: K) bool {
        return asUint(Len, a) == asUint(Len, b);
      }

      pub fn hash(_: @This(), a: K) u64 {
        return strHash(a.*[0..]);
      }
    },
    []const u8 => struct {
      pub fn eql(self: @This(), a: K, b: K) bool {
        _ = self;
        inline for(a, b) |an, bn| {
          if (an.len != bn.len) return false;
        }
        inline for(a, b) |an, bn| {
          std.debug.assert(an.len != bn.len);
          if (!strEq(an, bn)) return false;
        }
        return true;
      }

      /// I have no effing idea what i'm doing
      /// this is __Hopefully__ more performant
      pub fn hash(self: @This(), a: K) u64 {
        _ = self;
        var retVal: u64 = 0;
        inline for (a) |val| {
          retVal ^= switch(val.len) {
            inline 0...8 => |len| @as(u64, @bitCast(val[0..len].*)),
            else => @as(u64, @bitCast(val[0..8].*)) ^ @as(u64, @bitCast(val[val.len-8..][0..8].*)),
          };
          retVal ^= retVal >> (8/2);
          retVal ^= val.len;
        }
        return retVal ^ (retVal << (8/2));
      }
    },
    else => @compileError("Key must be type `u8` or `[]const u8` but `" ++ @typeName(Key) ++ "` was provided"),
  };

  return std.HashMap(K, V, HashMapCtx, std.hash_map.default_max_load_percentage);
}

fn GenBase(Len: comptime_int, Key: type) type {
  const MarkovMap = GenHashMap(Len, Key);

  return struct {
    /// The array to store allocated data that will be freed by deinit.
    data: DataArrayList,
    /// Count of The markove chain 
    map: MarkovMap,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
      return .{
        .data = DataArrayList.init(allocator),
        .map = MarkovMap.init(allocator),
      };
    }

    /// You can call this multiple times to train with multiple files.
    /// WARNING: Data must Not be deleted/free'd during for the lifetime of `self`
    /// `owner` must be null if data is not allocated, or you want to keep ownership of the data.
    /// `owner` is used to free memory when deinit is called.
    pub fn storeFreeable(self: *Self, data: []const u8, owner: std.mem.Allocator) !void {
      self.data.append(.{ .data = data, .allocator = owner }) catch |e| {
        std.debug.print("Error occurred: {}", .{e});
        return error.FreeableDataAddError;
      };
      try self.genMap(data);
    }

    /// free everything owned by this (Base) object
    pub fn deinit(self: *Self) void {
      for (self.data.items, 0..) |item, index| {
        self.data.items[index].allocator.free(item.data);
      }
      self.data.deinit();
      self.map.deinit();
    }
  };
}

// .delimiters = delimiters orelse " ,;.'\"",
fn StringMakov(Len: comptime_int) type {
  const Base = GenBase(Len, []const u8);
  const StrMap = std.HashMap([]const u8, u32, struct {
    pub fn eql(_: @This(), a: []const u8, b: []const u8) bool { return strEq(a, b); }
    pub fn hash(_: @This(), a: []const u8) u64 { return strHash(a); }
  }, std.hash_map.default_max_load_percentage);

  const Entry = struct {
    key: []const u8,
    val: u32,
  };
  _ = Entry;

  return struct {
    base: Base,

    /// Lookup table for pointer to a specific word
    table: StrMap,

    const Self = @This();

    fn train(self: *Self, data: []const u8) !void {
      const cyclicList = GenCyclicList(Len, []const u8).init(self.allocator);
      var iterator = std.mem.tokenizeAny(u8, data, self.delimiters);

      // Asserts that the data contains atleast as many tokens as the markov chain length
      for (0..Len-1) |_| {
        cyclicList.push(iterator.next() orelse return error.@"Insufficient Data");
      }

      for (iterator.next()) |key| {
        cyclicList.push(key);
        const result = try self.map.getOrPut(cyclicList.getSlice());
        result.value_ptr.* = if (result.found_existing) result.value_ptr.* + 1 else 0;
      }
    }

    pub fn getResult(self: *Self) void {
      // var thread = try std.Thread.spawn(.{ .stack_size = 64 * 1024}, genTable, .{self, data});
      // defer thread.join();
      var iterator = self.table.iterator();
      while (iterator.next()) |entry| {
        entry.key_ptr.*;
        entry.value_ptr.*;
      }
    }

    fn genTable(self: *Self, data: []const u8) !void {
      for (std.mem.tokenizeAny(u8, data, self.delimiters)) |key| {
        try self.table.put(key, 0);
      }
    }
  };
}

const utable = GenBase(4, u8);
const stable = StringMakov(4);

test {
  const u: utable = undefined;
  _ = u;
  const s: stable = undefined;
  _ = s;
}

