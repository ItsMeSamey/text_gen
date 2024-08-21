const std = @import("std");

const strEq = @import("common/stringComparer.zig").strEq;
const strHash = std.hash_map.hashString;

const Table = std.HashMap([]const u8, u32, struct {
  pub fn eql(_: @This(), a: []const u8, b: []const u8) bool { return strEq(a, b); }
  pub fn hash(_: @This(), a: []const u8) u64 { return strHash(a); }
}, std.hash_map.default_max_load_percentage);

const StringArray = std.ArrayList([]const u8);

const StringMakovOptions = struct {
  /// The characters that we should split at
  delim: ?[]const u8,
  /// Characters we should skip
  skip: ?[]const u8,
  /// The data owner (only used for free)
  allocator: std.mem.Allocator,
};

fn StringMakov(Len: comptime_int) type {
  const CyclicList = @import("common/cyclicList.zig").GenCyclicList(Len, []const u8);
  const Base = @import("common/markov.zig").GenBase(Len, u32);

  return struct {
    /// The base containing the modal
    base: Base,
    /// Lookup table for pointer to a specific word
    table: Table,
    /// The array that has every word that needs to exist
    array: StringArray,
    /// The cyclic list use for internal stuff
    cyclicList: CyclicList,

    const Self = @This();

    /// Create the instance of `@This()` object
    pub fn init(allocator: std.mem.Allocator) type {
      return .{
        .base = Base.init(allocator),
        .table = Table.init(allocator),
        .array = StringArray.init(allocator),
        .cyclicList = CyclicList.init(allocator),
      };
    }

    /// You can call this multiple times to train with multiple files.
    /// WARNING: Data must Not be deleted/free'd during for the lifetime of `self`
    /// `owner` must be null if data is not allocated, or you want to keep ownership of the data.
    /// `owner` is used to free memory when deinit is called.
    fn train(self: *Self, data: []const u8, options: StringMakovOptions) !void {
      if (options.allocator != null) {
        try self.base.storeFreeable(data, options.allocator.?);
      }
      var iterator = std.mem.tokenizeAny(u8, data, options.delim);

      for (0..Len-1) |_| {
        // You MUST ensure that length of words in data is more than the chain length for each function call
        try self.turn(iterator.next() orelse return error.@"Insufficient Data", options.skip);
      }

      for (iterator.next()) |key| {
        try self.turn(key, options.skip);
        try self.base.increment(self.cyclicList.getSlice());
      }
    }

    /// Turn the `self.cyclicList`
    /// Remove all the occurrences of skip characters from allocated copy of val.
    /// If it is not already added, we add the word to end of `self.array`
    ///   and set `self.table[val]` = index we inserted the word at (in `self.array`)
    /// The index is then used as a unique identifier for that word.
    fn turn(self: *Self, val: []const u8, skip: []const u8) !void {
      var dest = try self.array.allocator.alloc(u8, val.len);
      @memcpy(dest, val);
      var eb: usize = 0;
      for (dest.len, 0..) |character, index| {
        if (std.mem.indexOfScalar(skip, character) != null) {
          eb += 1;
        } else {
          dest[index - eb] = character;
        }
      }
      dest.len -= eb;

      const result = try self.table.getOrPut(dest);
      if (result.found_existing) {
        self.cyclicList.push(result.value_ptr.*);
        self.array.allocator.free(dest);
      } else {
        self.cyclicList.push(self.array.items.len);
        try self.array.allocator.resize(dest, eb);
        try self.array.append(dest);
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

    pub fn deinit(self: *Self) void {
      while (self.array.items) |key| { self.table.allocator.free(key); }

      self.base.deinit();
      self.table.deinit();
      self.array.deinit();
    }
  };
}

const stable = StringMakov(4);

test {
  const s: stable = undefined;
  _ = s;
}

