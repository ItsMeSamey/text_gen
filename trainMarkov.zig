const std = @import("std");
const MarkovBase = @import("common/markov/markovBase.zig");
const defaults = @import("common/markov/defaults.zig");
const GenCyclicList = @import("common/markov/cyclicList.zig").GenCyclicList;

pub fn CharMakov(Len: usize) type {
  const Base = MarkovBase.GenBase(Len, defaults.CharKey, defaults.Val);

  return struct {
    /// The base containing the modal
    base: Base,

    /// Create the instance of `@This()` object
    pub fn init(allocator: std.mem.Allocator) !@This() {
      return .{ .base = Base.init(allocator) };
    }

    /// You can call this multiple times to train with multiple files.
    /// WARNING: Data must Not be deleted/free'd for the lifetime of `self`
    pub fn train(self: *@This(), data: []const u8) !void {
      if (data.len < Len) return error.InsufficientData;
      for (0..data.len-(Len-1)) |i| {
        try self.base.increment(data[i..][0..Len].*);
      }

      var stiching: [Len-1 + Len-1]u8 = undefined;
      @memcpy(stiching[0..Len-1], data[data.len-(Len-1)..][0..Len-1]);
      @memcpy(stiching[Len-1..], data[0..Len-1]);
      for (0..Len-1) |i| {
        try self.base.increment(stiching[i..][0..Len].*);
      }
    }

    /// Writes the data to `writer` deinitialize this object
    /// You will *NOT* need to call deinit() explicitly
    pub fn write(self: *@This(), writer: std.io.AnyWriter) !void {
      return self.base.write(writer, u8);
    }

    pub fn deinit(self: *@This()) void {
      self.base.deinit();
    }
  };
}

pub fn WordMakov(Len: usize) type {
  const Table = std.StringArrayHashMap(u32);
  const CyclicList = GenCyclicList(Len, defaults.WordKey);
  const Base = MarkovBase.GenBase(Len, defaults.WordKey, defaults.Val);

  return struct {
    /// The base containing the modal
    base: Base,
    /// Lookup table for pointer to a specific word
    table: Table,

    /// Create the instance of `@This()` object
    pub fn init(allocator: std.mem.Allocator) !@This() {
      return .{
        .base = Base.init(allocator),
        .table = Table.init(allocator),
      };
    }

    /// You can call this multiple times to train with multiple files.
    /// NOTE: **no** references to `data` are stored so it *can* be deleted immediately after this call
    /// If length of words in data is less than the chain length, this function will return error.InsufficientData
    pub fn train(self: *@This(), data: []const u8) !void {
      var cyclicList: CyclicList = .{};

      var iterator = std.mem.tokenizeScalar(u8, data, 0);
      for (0..Len-1) |_| {
        // You MUST ensure that length of words in data is more than the chain length for each function call
        try self.turn(iterator.next() orelse return error.InsufficientData, &cyclicList);
      }

      var beginning:[Len-1]defaults.WordKey = undefined;
      @memcpy(&beginning, cyclicList.buf[0..Len-1]);

      while (iterator.next()) |key| {
        try self.turn(key, &cyclicList);
        try self.base.increment(cyclicList.getSlice().*);
      }

      for (beginning) |val| {
        cyclicList.push(val);
        try self.base.increment(cyclicList.getSlice().*);
      }
    }

    /// Turn the `self.cyclicList`
    /// If not added before, we add the word to end of `self.array`
    ///   and set `self.table[val]` = index we inserted the word at (in `self.array`)
    /// The index is then used as a unique identifier for that word.
    fn turn(self: *@This(), val: []const u8, cyclicList: *CyclicList) !void {
      const result = try self.table.getOrPut(val);
      if (!result.found_existing) {
        const str = try self.table.allocator.alloc(u8, val.len);
        @memcpy(str, val);
        result.key_ptr.* = str;
        result.value_ptr.* = @intCast(self.table.count());
      }

      cyclicList.push(result.value_ptr.*);
    }

    /// Writes the data to `writer` deinitialize this object
    /// You will *NOT* need to call deinit() explicitly
    pub fn write(self: *@This(), writer: std.io.AnyWriter) !void {
      if (std.math.maxInt(u64) < self.table.count()) @panic("Table too large!");

      inline for (1..4) |intLen| {
        const IntType = std.meta.Int(.unsigned, 8 * (1 + intLen));
        if (std.math.maxInt(IntType) >= self.table.count()) {
          try self.base.write(writer, IntType);
          break;
        }
      }

      var count: u64 = 0;
      // since insertion order is preserved, we can just write the keys like this
      for (self.table.keys()) |key| {
        count += key.len + 1; // +1 for the null terminator
        try writer.writeAll(key);
        try writer.writeAll(&[_]u8{0});
      }
      try writer.writeInt(u64, count, defaults.Endian);
    }

    pub fn deinit(self: *@This()) void {
      self.base.deinit();
      for (self.table.keys()) |key| { self.table.allocator.free(key); }
      self.table.deinit();
    }
  };
}

test {
  std.testing.refAllDecls(CharMakov(4));
  std.testing.refAllDecls(WordMakov(4));
}

