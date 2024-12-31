const std = @import("std");
const GenBase = @import("common/markov/markovBase.zig").GenBase;
const defaults = @import("common/markov/defaults.zig");
const GenCyclicList = @import("common/markov/cyclicList.zig").GenCyclicList;

fn CharMakov(Len: comptime_int) type {
  const Base = GenBase(Len, defaults.CharKey, defaults.Val);
  const CyclicList = GenCyclicList(Len, u8);

  return struct {
    /// The base containing the modal
    base: Base,
    beginningList: CyclicList = .{},

    /// Create the instance of `@This()` object
    pub fn init(allocator: std.mem.Allocator) !@This() {
      return .{ .base = Base.init(allocator) };
    }

    /// You can call this multiple times to train with multiple files.
    /// WARNING: Data must Not be deleted/free'd during for the lifetime of `self`
    /// `owner` must be null if data is not allocated, or you want to keep ownership of the data.
    /// `owner` is used to free memory when deinit is called.
    pub fn train(self: *@This(), data: []const u8) !void {
      if (data.len < Len) return error.InsufficientData;
      for (0..data.len-(Len-1)) |i| {
        try self.base.increment(data[i..][0..Len].*);
      }

      for (data.len-Len..data.len) |i| {
        self.beginningList.push(data[i]);
      }

      for (0..Len-1) |i| {
        self.beginningList.push(data[i]);
        try self.base.increment(self.beginningList.getSlice().*);
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

fn WordMakov(Len: comptime_int) type {
  const Table = std.StringArrayHashMap(u32);
  const CyclicList = GenCyclicList(Len, defaults.WordKey);
  const Base = GenBase(Len, defaults.WordKey, defaults.Val);

  return struct {
    /// The base containing the modal
    base: Base,
    /// Lookup table for pointer to a specific word
    table: Table,
    count: u32 = 0,
    /// The cyclic list use for internal stuff
    cyclicList: CyclicList = .{},
    beginning: [Len-1]defaults.Val = undefined,

    /// Create the instance of `@This()` object
    pub fn init(allocator: std.mem.Allocator) !@This() {
      return .{
        .base = Base.init(allocator),
        .table = Table.init(allocator),
      };
    }

    /// You can call this multiple times to train with multiple files.
    /// NOTE: **no** references to `data` are stored so it *can* be deleted immediately after this call
    pub fn train(self: *@This(), data: []const u8) !void {
      var iterator = std.mem.tokenizeScalar(u8, data, 0);
      for (0..Len-1) |_| {
        // You MUST ensure that length of words in data is more than the chain length for each function call
        try self.turn(iterator.next() orelse return error.InsufficientData);
      }

      @memcpy(&self.beginning, self.cyclicList.buf[0..Len-1]);

      while (iterator.next()) |key| {
        try self.turn(key);
        try self.base.increment(self.cyclicList.getSlice().*);
      }

      for (self.beginning) |val| {
        self.cyclicList.push(val);
        try self.base.increment(self.cyclicList.getSlice().*);
      }
    }

    /// Turn the `self.cyclicList`
    /// If not added before, we add the word to end of `self.array`
    ///   and set `self.table[val]` = index we inserted the word at (in `self.array`)
    /// The index is then used as a unique identifier for that word.
    fn turn(self: *@This(), val: []const u8) !void {
      const result = try self.table.getOrPut(val);
      if (!result.found_existing) {
        const str = try self.table.allocator.alloc(u8, val.len);
        @memcpy(str, val);
        result.key_ptr.* = str;
        result.value_ptr.* = self.count;
        self.count += 1;
      }

      self.cyclicList.push(result.value_ptr.*);
    }

    /// Writes the data to `writer` deinitialize this object
    /// You will *NOT* need to call deinit() explicitly
    pub fn write(self: *@This(), writer: std.io.AnyWriter) !void {
      if (std.math.maxInt(u64) < self.table.count()) @panic("Table too large!");

      inline for (0..4) |intLen| {
        const intType = std.meta.Int(.unsigned, 8 * (1 << intLen));
        if (std.math.maxInt(intType) >= self.table.count()) {
          try self.base.write(writer, intType);
          break;
        }
      }

      var count: u64 = 0;
      for (self.table.keys()) |key| {
        count += key.len + 1; // +1 for null terminator
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

fn readAllMerged(allocator: std.mem.Allocator, dir: std.fs.Dir) ![]u8 {
  var walker = try dir.walk(allocator);
  defer walker.deinit();

  var files = std.ArrayListUnmanaged(std.fs.File){};
  defer {
    for (files.items) |*file| file.close();
    files.deinit(allocator);
  }

  var size: usize = 0;
  while (try walker.next()) |entry| {
    var file = try entry.dir.openFile(entry.basename, .{});
    const stats = try file.stat();
    size += stats.size + 1; // +1 for the extra newline
    try files.append(allocator, file);
  }

  var memory = try allocator.alloc(u8, size);
  errdefer allocator.free(memory);

  size = 0;
  for (files.items) |file| {
    const n = try file.readAll(memory[size..]);
    std.debug.assert(n < memory[size..].len);
    size += n;
    memory[size] = '\n';
    size += 1;
  }

  std.debug.assert(size == memory.len);

  return memory;
}

fn filterAllowed(str: []u8) []u8 {
  var idx: usize = 0;
  var encountered: bool = false;
  for (str) |char_| {
    const char = std.ascii.toLower(char_);
    if (
      (char >= 'a' and char <= 'z') or
      (char >= '0' and char <= '9')
    ) {
      if (encountered) {
        encountered = false;
        str[idx] = '\x00';
        idx += 1;
      }
      str[idx] = char;
      idx += 1;
    } else {
      switch (char) {
        '\'' => {},
        else => {
          encountered = true;
        },
      }
    }
  }

  return str[0..idx];
}

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer _ = gpa.deinit();
  const allocator = gpa.allocator();

  var data_dir = try std.fs.cwd().openDir("data", .{});
  defer data_dir.close();

  var markov_dir = try data_dir.openDir("markov", .{ .iterate = true, .no_follow = true });
  defer markov_dir.close();

  const file_text = try readAllMerged(allocator, markov_dir);
  defer allocator.free(file_text);
  const training_data = filterAllowed(file_text);

  // std.debug.print("Training data: {s}\n", .{file_text});

  { // Train word makov model
    var makov = try WordMakov(4).init(allocator);
    defer makov.deinit();
    try makov.train(training_data);

    var markov_file = try data_dir.createFile("markov.word", .{});
    defer markov_file.close();

    var buffered = std.io.bufferedWriter(markov_file.writer().any());
    try makov.write(buffered.writer().any());
    try buffered.flush();
  }

  { // Train char makov model
    var makov = try CharMakov(8).init(allocator);
    defer makov.deinit();
    try makov.train(training_data);

    var markov_file = try data_dir.createFile("markov.char", .{});
    defer markov_file.close();

    var buffered = std.io.bufferedWriter(markov_file.writer().any());
    try makov.write(buffered.writer().any());
    try buffered.flush();
  }
}

