const std = @import("std");
const GenBase = @import("common/markov/trainMarkov.zig").GenBase;

const strEq = @import("common/markov/stringComparer.zig").strEq;
const strHash = std.hash_map.hashString;

const Table = std.ArrayHashMap([]const u8, u32, struct {
  pub fn eql(_: @This(), a: []const u8, b: []const u8) bool { return strEq(a, b); }
  pub fn hash(_: @This(), a: []const u8) u64 { return strHash(a); }
}, true);

fn WordMakov(Len: comptime_int) type {
  const CyclicList = @import("common/markov/cyclicList.zig").GenCyclicList(Len, []const u8);
  const Base = GenBase(Len, u32, u32);

  return struct {
    /// The base containing the modal
    base: Base,
    /// Lookup table for pointer to a specific word
    table: Table,
    count: usize = 0,
    /// The cyclic list use for internal stuff
    cyclicList: CyclicList = .{},

    const Self = @This();

    /// Create the instance of `@This()` object
    pub fn init(allocator: std.mem.Allocator) !Self {
      return .{
        .base = Base.init(allocator),
        .table = Table.init(allocator),
      };
    }

    /// You can call this multiple times to train with multiple files.
    /// NOTE: `data` *can* be deleted immediately after this call
    pub fn train(self: *Self, data: []const u8) !void {
      var iterator = std.mem.tokenizeScalar(u8, data, 0);
      for (0..Len-1) |_| {
        // You MUST ensure that length of words in data is more than the chain length for each function call
        try self.turn(iterator.next() orelse return error.InsufficientData);
      }

      for (iterator.next()) |key| {
        try self.turn(key);
        try self.base.increment(self.cyclicList.getSlice());
      }
    }

    /// Turn the `self.cyclicList`
    /// If not added before, we add the word to end of `self.array`
    ///   and set `self.table[val]` = index we inserted the word at (in `self.array`)
    /// The index is then used as a unique identifier for that word.
    fn turn(self: *Self, val: []const u8) !void {
      const result = try self.table.getOrPutAdapted(val);
      if (!result.found_existing) {
        result.key_ptr.* = try self.table.allocator.alloc(val.len);
        @memcpy(result.key_ptr.*, val);
        result.value_ptr.* = self.count;
        self.count += 1;
      }

      self.cyclicList.push(result.value_ptr.*);
    }

    /// Writes the data to `writer` does *NOT* deinitialize anything
    pub fn flush(self: *Self, writer: std.io.AnyWriter) void {
      var count: u64 = 0;
      for (self.table.keys()) |key| {
        count += 1;
        try writer.writeAll(key);
      }
      self.base.flush(writer, self.table.count());
      try writer.writeInt(u64, count, .little);
      try writer.writeAll("word");
    }

    pub fn deinit(self: *Self) void {
      self.base.deinit();

      for (self.table.keys()) |key| { self.table.allocator.free(key); }
      self.table.deinit();
    }
  };
}

fn CharMakov(Len: comptime_int) type {
  const Base = GenBase(Len, u8, u32);

  return struct {
    /// The base containing the modal
    base: Base,

    const Self = @This();

    /// Create the instance of `@This()` object
    pub fn init(allocator: std.mem.Allocator) type {
      return .{ .base = Base.init(allocator) };
    }

    /// You can call this multiple times to train with multiple files.
    /// WARNING: Data must Not be deleted/free'd during for the lifetime of `self`
    /// `owner` must be null if data is not allocated, or you want to keep ownership of the data.
    /// `owner` is used to free memory when deinit is called.
    pub fn train(self: *Self, data: []const u8, owner: ?std.mem.Allocator) !void {
      if (data.len < Len) return error.InsufficientData;
      if (owner != null) { try self.base.storeFreeable(data, owner.?); }
      for (0..data.len-(Len-1)) |i| {
        try self.base.increment(data[i..i+Len]);
      }
    }

    /// Writes the data to `writer` does *NOT* deinitialize anything
    pub fn flush(self: *Self, writer: std.io.AnyWriter) void {
      self.base.flush(writer, std.math.maxInt(u8));
      try writer.writeAll("char");
    }

    pub fn deinit(self: *Self) void {
      self.base.deinit();
    }
  };
}

test {
  {
    const s: CharMakov(4) = undefined;
    _ = s;
  }
  {
    const s: WordMakov(4) = undefined;
    _ = s;
  }
}

