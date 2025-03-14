const std = @import("std");
const builtin = @import("builtin");

const meta = @import("common/markov/meta.zig");
const defaults = @import("common/markov/defaults.zig");
const markovStats = @import("common/markov/markovStats.zig");
const MarkovModelStats = markovStats.ModelStats;

/// Make a cyclic list with a list of given type T
/// Len is maximum len of a cycle,
/// You may want to call `GenPaddedCyclicList` with a larger multiplier of `Len`
/// to get better performance (depending on your usage).
pub fn GenCyclicList(Len: comptime_int, T: type) type {
  // -> this is arbitrarily chosen
  comptime var len = 1;
  while (len < Len) : (len *= 2) {}
  len *= 8;
  // <-

  return GenPaddedCyclicList(Len, len, T);
}

/// Make a cyclic list with a list of given type T
/// Len is maximum len of a cycle,
/// BufLen is the length of buffer
pub fn GenPaddedCyclicList(Len: comptime_int, BufLen: comptime_int, T: type) type {
  comptime {
    if (Len <= 0) @compileError("Cannot have a zero-sized cyclic list");
    if (BufLen <  Len) @compileError("Buffer length cannot be smaller than Capacity of cyclic list");
  }

  return struct {
    /// The buffer used for cyclic list
    buf: [BufLen]T = undefined,
    /// end of the buffer
    end: usize = 0,

    /// Sihft elements around so that we have a contiguous slice of active elements.
    fn emplace(self: *@This()) void {
      if (self.end > Len) return;

      if (BufLen >= Len * 2 or BufLen - Len >= Len - self.end) {
        std.mem.copyBackwards(T, self.buf[Len-self.end..Len], self.buf[0..self.end]);
        @memcpy(self.buf[0..Len-self.end], self.buf[BufLen-(Len-self.end)..BufLen]);
      } else {
        std.mem.rotate(T, &self.buf, BufLen - (Len - self.end));
      }
      self.end = Len;
    }

    /// The array rotate so a contiguous slice can be return
    pub fn getSlice(self: *@This()) *[Len]T {
      self.emplace();
      return self.buf[self.end-Len..][0..Len];
    }

    /// Push an element to the array. This is cheap as
    /// `self.buf` is not rotated unless `self.getSlice` is called
    pub fn push(self: *@This(), val: T) void {
      self.buf[self.end] = val;
      self.end = if (self.end + 1 == self.buf.len) 0 else self.end + 1;
    }
  };
}

test GenPaddedCyclicList {
  const testList = struct {
    fn testList(Len: comptime_int, BufLen: comptime_int) !void {
      const ListType = GenPaddedCyclicList(Len, BufLen, usize);
      var list = ListType{};
      inline for (0..BufLen+(Len/2)) |i| list.push(i);
      const slice = list.getSlice();
      inline for (BufLen+(Len/2)-Len..BufLen+(Len/2), 0..) |v, i| try std.testing.expect(v == slice[i]);
    }
  }.testList;

  try testList(2, 2);
  try testList(2, 3);
  try testList(2, 4);
  try testList(2, 9);
  try testList(3, 16);
  try testList(3, 3);
  try testList(3, 4);
  try testList(5, 5);
  try testList(5, 7);
  try testList(5, 8);
  try testList(5, 9);
  try testList(5, 16);
}

/// A base onject to store the frequency of occurrence a sequence
/// if `Key` is u8, assumes a char model
/// The Val type here is used only during model creation
pub fn GenBase(Len: comptime_int, Key: type, Val: type) type {
  // Validate inputs
  _ = MarkovModelStats.init(Len, Key, Val, defaults.Endian);

  // Done this way so we can easily sort the keys array without copying
  const MarkovMap = std.AutoArrayHashMap([Len]Key, Val);

  return struct {
    /// Count of The markove chain
    map: MarkovMap,

    pub const LENGTH: u8 = Len;

    pub fn init(allocator: std.mem.Allocator) @This() {
      return .{
        .map = MarkovMap.init(allocator),
      };
    }

    /// Increment the value for encountered key
    pub fn increment(self: *@This(), key: [Len]Key) !void {
      const result = try self.map.getOrPut(key);
      if (result.found_existing) {
        result.value_ptr.* += 1;
      } else {
        result.value_ptr.* = 0;
      }
    }

    /// Writes the data to `writer` and deinitializes this object and hence should be only called once
    /// `MinKeyType` tells us what is the minimum possible int size needed for key values
    /// `MinKeyType` = `u8` must be used only for char model
    pub fn write(self: *@This(), writer: std.io.AnyWriter, comptime MinKeyType: type) !void {
      try MarkovModelStats.init(Len, MinKeyType, Val, defaults.Endian).flush(writer);

      const TableKey = meta.TableKey(MinKeyType, Val);
      const TableVal = meta.TableVal(MinKeyType, Val);

      const keys_list = self.map.keys();
      const vals_list = self.map.values();

      std.sort.pdqContext(0, self.map.count(), struct {
        k: [][Len]Key,
        v: []Val,

        pub fn lessThan(me: @This(), lidx: usize, ridx: usize) bool {
          const lhs = me.k[lidx];
          const rhs = me.k[ridx];
          inline for (0..Len-1) |i| if (lhs[i] != rhs[i]) return lhs[i] < rhs[i];
          return false;
        }
        pub fn swap(me: @This(), a: usize, b: usize) void {
          std.mem.swap([Len]Key, &me.k[a], &me.k[b]);
          std.mem.swap(Val, &me.v[a], &me.v[b]);
        }
      }{
        .k = keys_list,
        .v = vals_list,
      });

      // Make a list if all the keys
      var list = std.ArrayList(struct { key: [Len-1]Key, from: u32, next: u32 = undefined }).init(self.map.allocator);
      defer list.deinit();

      try list.append(.{
        .key = keys_list[0][0..Len-1].*,
        .from = 0,
      });
      for (keys_list, 0..) |k, from| {
        if (meta.arrAsUint(list.getLast().key) == meta.arrAsUint(k[0..Len-1])) continue;
        try list.append(.{
          .key = k[0..Len-1].*,
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

          // Partition point returns start/low instead of mid (as the result)
          mid = start;

          if (builtin.mode == .Debug and mid < list.items.len and !std.mem.eql(Key, entry.key[1..], list.items[mid].key[0..Len-2])) {
            std.debug.panic("Partition point: {any}\nentry: {any}, next_entry: {any}", .{mid, entry.*, list.items[mid]});
          }
        }

        entry.next = mid;
        try meta.writePackedStructEndian(writer, TableKey{
          .key = @intCast(entry.key[Len-2]),
          .value = @intCast(entry.from),
          .next = mid,
        }, defaults.Endian);
      }

      // The last (extra) key to make computation easier, see genMarkov.zig's GetMarkovGen.Generator.gen
      try meta.writePackedStructEndian(writer, TableKey{
        .key = std.math.maxInt(MinKeyType), // this is never used so it may be undefined, but that triggers ub protection
        .value = @intCast(keys_list.len),
        .next = std.math.maxInt(u32),
      }, defaults.Endian);

      // Write keys length (+1 for the extra entry at the end)
      try writer.writeInt(u64, (list.items.len + 1) * ((@bitSizeOf(TableKey) + 7) >> 3), defaults.Endian);

      // Write values
      var index: u32 = 0;
      var val: Val = 0;
      for (keys_list, vals_list) |k, v| {
        if (meta.arrAsUint(k[0..Len-1]) != meta.arrAsUint(list.items[index].key)) {
          index += 1;
          val = 0;
          std.debug.assert(index < list.items.len);
          std.debug.assert(meta.arrAsUint(k[0..Len-1]) == meta.arrAsUint(list.items[index].key));
        }

        var mid: u32 = undefined;
        var start: u32 = list.items[index].next;
        var end: u32 = @intCast(list.items.len);
        while (start < end) {
          mid = start + (end - start) / 2;
          switch (std.mem.order(Key, list.items[mid].key[0..], k[1..])) {
            .lt => start = mid + 1,
            .gt => end = mid,
            .eq => break,
          }
        }

        if (builtin.mode == .Debug and !std.mem.eql(Key, k[1..], list.items[mid].key[0..])) {
          std.debug.print("Expected: {any}, {any}\n", .{k, v});
          std.debug.print("Start: {any}\n", .{list.items[list.items[index].next]});
          std.debug.print("Mid: {any}\n", .{list.items[mid]});
          unreachable;
        }

        val += v;
        try meta.writePackedStructEndian(writer, TableVal{
          .val = val,
          .subnext = @intCast(mid - list.items[index].next),
        }, defaults.Endian);
        val += 1;
      }

      try writer.writeInt(u64, (keys_list.len) * ((@bitSizeOf(TableVal) + 7) >> 3), defaults.Endian);
    }

    /// Free this struct
    pub fn deinit(self: *@This()) void {
      self.map.deinit();
    }

    /// Clone this struct
    pub fn clone(self: *@This()) !@This() {
      return .{.map = try self.map.clone()};
    }
  };
}

test GenBase {
  std.testing.refAllDecls(GenBase(2, defaults.CharKey, defaults.Val));
  std.testing.refAllDecls(GenBase(2, defaults.WordKey, defaults.Val));
}

pub fn CharMakov(Len: usize) type {
  const Base = GenBase(Len, defaults.CharKey, defaults.Val);
  const CyclicList = GenCyclicList(Len, defaults.CharKey);

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

      var cyclicList: CyclicList = .{};
      for (data[data.len-(Len-1)..]) |c| cyclicList.push(c);
      if (data[data.len-1] != 0 and data[0] != 0) {
        cyclicList.push(0);
        try self.base.increment(cyclicList.getSlice().*);
      }

      for (data[0..Len-1]) |c| {
        cyclicList.push(c);
        try self.base.increment(cyclicList.getSlice().*);
      }
    }

    /// Writes the data to `writer` deinitialize this object
    /// You will *NOT* need to call deinit() explicitly
    pub fn write(self: *@This(), writer: std.io.AnyWriter) !void {
      return self.base.write(writer, u8);
    }

    /// Deinit everything belonging to this struct
    pub fn deinit(self: *@This()) void {
      self.base.deinit();
    }

    /// Create a copy of this struct to be able to be used later
    pub fn clone(self: *@This()) !@This() {
      return .{.base = try self.base.clone()};
    }
  };
}

test CharMakov {
  std.testing.refAllDecls(CharMakov(2));
}

pub fn WordMakov(Len: usize) type {
  const Table = std.StringArrayHashMap(u32);
  const CyclicList = GenCyclicList(Len, defaults.WordKey);
  const Base = GenBase(Len, defaults.WordKey, defaults.Val);

  return struct {
    /// The base containing the modal
    base: Base,
    /// Lookup table for pointer to a specific word
    table: Table,
    /// This reference count of this struct, only use in .deinit() and .clone()
    count: *std.atomic.Value(u32),

    /// Create the instance of `@This()` object
    pub fn init(allocator: std.mem.Allocator) !@This() {
      const retval: @This() = .{
        .base = Base.init(allocator),
        .table = Table.init(allocator),
        .count = try allocator.create(std.atomic.Value(u32)),
      };
      retval.count.store(1, .unordered);
      return retval;
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
        result.value_ptr.* = @intCast(self.table.count() - 1); // Since the new entry is counted as well in `table.count()`
      }

      cyclicList.push(result.value_ptr.*);
    }

    /// Writes the data to `writer` deinitialize this object
    /// You will *NOT* need to call deinit() explicitly
    pub fn write(self: *@This(), writer: std.io.AnyWriter) !void {
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

    /// Deinit everything belonging to this struct
    pub fn deinit(self: *@This()) void {
      const count = self.count.fetchSub(1, .monotonic);
      if (count == 1) {
        self.base.map.allocator.destroy(self.count);
        for (self.table.keys()) |key| { self.table.allocator.free(key); }
      }
      self.table.deinit();
      self.base.deinit();
    }

    /// Create a copy of this struct to be able to be used later
    pub fn clone(self: *@This()) !@This() {
      const count = self.count.fetchAdd(1, .monotonic);
      if (count == 0) return error.AlreadyFreed; // struct has already been freed by someone else

      var base = try self.base.clone();
      errdefer base.deinit();
      var table = try self.table.clone();
      defer table.deinit();
      return .{.base = base, .table = table, .count = self.count};
    }
  };
}

test WordMakov {
  std.testing.refAllDecls(WordMakov(4));
}

const TrainingImplementation = struct {
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

  pub fn bufferedWriter(comptime buf_len: comptime_int, underlying_stream: anytype) std.io.BufferedWriter(buf_len, @TypeOf(underlying_stream)){
    return .{ .unbuffered_writer = underlying_stream };
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
    var timer = try std.time.Timer.start();

    { // Train word makov model
      var makov = try WordMakovType.init(allocator);
      defer makov.deinit();
      timer.reset();
      try makov.train(training_data);
      std.debug.print("Word Makov took {d}ms\n", .{@as(f128, @floatFromInt(timer.read()))/@as(f128, @floatFromInt(std.time.ns_per_ms))});

      var markov_file = try data_dir.createFile("markov.word", .{});
      defer markov_file.close();

      var buffered = bufferedWriter(1 << 20, markov_file.writer().any());
      timer.reset();
      try makov.write(buffered.writer().any());
      try buffered.flush();
      std.debug.print("Word Makov write took {d}ms\n", .{@as(f128, @floatFromInt(timer.read()))/@as(f128, @floatFromInt(std.time.ns_per_ms))});
    }

    { // Train char makov model
      var makov = try CharMakovType.init(allocator);
      defer makov.deinit();
      timer.reset();
      try makov.train(training_data);
      std.debug.print("Char Makov took {d}ms\n", .{@as(f128, @floatFromInt(timer.read()))/@as(f128, @floatFromInt(std.time.ns_per_ms))});

      var markov_file = try data_dir.createFile("markov.char", .{});
      defer markov_file.close();

      var buffered = bufferedWriter(1 << 20, markov_file.writer().any());
      timer.reset();
      try makov.write(buffered.writer().any());
      try buffered.flush();
      std.debug.print("Char Makov write took {d}ms\n", .{@as(f128, @floatFromInt(timer.read()))/@as(f128, @floatFromInt(std.time.ns_per_ms))});
    }
  }

  fn getValidator(Len: comptime_int, K: type, V: type, endian: std.builtin.Endian) (
    fn (markov: anytype, tk_slice: []const u8, tv_slice: []const u8) void
  ) {
    const TableKey = meta.TableKey(K, V);
    const TableVal = meta.TableVal(K, V);

    const sizeTableKey = (@bitSizeOf(TableKey) + 7) >> 3;
    const sizeTableVal = (@bitSizeOf(TableVal) + 7) >> 3;

    const Key = if (K != u8) defaults.WordKey else defaults.CharKey;
    const BaseType = GenBase(Len, Key, defaults.Val);

    return struct {
      const log_list = false;
      const log_validate = false;

      var arr: [Len]Key = undefined;
      var tk_slice: []const u8 = undefined;
      var tv_slice: []const u8 = undefined;
      var from: usize = undefined;
      var last_count: V = undefined;

      fn validate(comptime depth: comptime_int, markov: anytype) void {
        if(log_validate) std.debug.print("Validating idx {d}, depth: {d}\n", .{from, depth});

        const from_slice = tk_slice[from..];
        const k0: TableKey = meta.readPackedStructEndian(TableKey, from_slice[0..sizeTableKey], endian);
        if(log_validate) {
          if (K == u8) {
            std.debug.print("k0: (.key = {c}, .value = {d}, .next = {d})\n", .{k0.key, k0.value, k0.next});
          } else {
            std.debug.print("k0: (.key = {s}, .value = {d}, .next = {d})\n", .{markov.table.keys()[k0.key], k0.value, k0.next});
          }
        }
        arr[depth] = k0.key;

        if (depth == Len-1) {
          const base: BaseType = markov.base;
          const mval = base.map.get(arr);
          if (mval == null or mval.? != last_count) {
            std.debug.print("Expected: {d:4}, got {d:4} for `", .{mval.?, last_count, });
            for (arr) |key| {
              if (K == u8) {
                std.debug.print("{c}", .{key});
              } else {
                std.debug.print("{s} ", .{markov.table.keys()[key]});
              }
            }
            if (K != u8) std.debug.print("\x08", .{});
            std.debug.print("`\n", .{});
          }
          return;
        }

        var last_read_count: V = 0;
        for (k0.value..meta.readPackedStructEndian(TableKey, from_slice[sizeTableKey..][0..sizeTableKey], endian).value) |i| {
          const val = meta.readPackedStructEndian(TableVal, tv_slice[i*sizeTableVal..][0..sizeTableVal], endian);
          if(log_validate) std.debug.print("val: {any}\n", .{val});

          last_count = val.val - last_read_count;
          last_read_count = val.val;

          from = (k0.next + val.subnext) * sizeTableKey;
          validate(depth+1, markov);
        }
      }

      fn validateAll(markov: anytype, tk: []const u8, tv: []const u8) void {
        tk_slice = tk;
        tv_slice = tv;
        var start: usize = 0;

        if (log_list) {
          var idx: usize = 0;
          std.debug.print("\nKeys:\n", .{});
          while (idx < tk_slice.len - sizeTableKey): (idx += sizeTableKey) {
            const k0: TableKey = meta.readPackedStructEndian(TableKey, tk_slice[idx..][0..sizeTableKey], endian);
            if (K == u8) {
              std.debug.print("{d:8}: (.value = {d:8}, .next = {d:8}, .key = {c})\n", .{idx, k0.value, k0.next, k0.key});
            } else {
              std.debug.print("{d:8}: (.value = {d:8}, .next = {d:8}, .key = {s})\n", .{idx, k0.value, k0.next, markov.table.keys()[k0.key]});
            }
            const k1: TableKey = meta.readPackedStructEndian(TableKey, tk_slice[idx+sizeTableKey..][0..sizeTableKey], endian);
            const vals = tv[k0.value*sizeTableVal..k1.value*sizeTableVal];
            var sub_idx: usize = 0;
            while (sub_idx < vals.len): (sub_idx += sizeTableVal) {
              const v: TableVal = meta.readPackedStructEndian(TableVal, vals[sub_idx..][0..sizeTableVal], endian);
              std.debug.print("\t{d:8}: v: (.subnext: {d:4}, .val: {d:4})\n", .{idx, v.subnext, v.val});
            }
          }
        }

        // `- sizeTableKey` to skip the extra entry at the end
        while (start < tk_slice.len - sizeTableKey): (start += sizeTableKey) {
          from = start;
          validate(0, markov);
        }
      }
    }.validateAll;
  }

  // This test takes quite a while to run so it is disabled by default
  // test TrainingImplementation {
  //   const allocator = std.testing.allocator;
  //   var data_dir = try std.fs.cwd().openDir("data", .{});
  //   defer data_dir.close();
  //
  //   var markov_dir = try data_dir.openDir("markov", .{ .iterate = true, .no_follow = true });
  //   defer markov_dir.close();
  //
  //   const file_text = try readAllMerged(allocator, markov_dir);
  //   defer allocator.free(file_text);
  //   const training_data = filterAllowed(file_text);
  //
  //   const GenMarkov = @import("genMarkov.zig");
  //
  //   { // Train word makov model
  //     var makov = try WordMakovType.init(allocator);
  //     defer makov.deinit();
  //     try makov.train(training_data);
  //
  //     const data = @embedFile("./data/markov.word");
  //     var loaded = try GenMarkov.initImmutableUncopyable(data, .{.allocator = allocator, .random = undefined});
  //     defer loaded.free(allocator);
  //
  //     const stats = comptime MarkovModelStats.fromBytes(data) catch unreachable;
  //     const model: *GenMarkov.GetMarkovGen(
  //       stats.key.Type(),
  //       stats.val.Type(),
  //       markovStats.EndianEnum.fromEndian(defaults.Endian)
  //     ) = @ptrCast(&loaded._data);
  //
  //     const keys_slice = model.generator.keys[0..model.generator.key_len];
  //     const vals_slice = model.generator.vals[0..model.generator.val_len];
  //
  //     const validate = getValidator(@TypeOf(makov.base).LENGTH, stats.key.Type(), stats.val.Type(), defaults.Endian);
  //
  //     validate(makov, keys_slice, vals_slice);
  //   }
  //
  //   { // Train char makov model
  //     var makov = try CharMakovType.init(allocator);
  //     defer makov.deinit();
  //     try makov.train(training_data);
  //
  //     const data = @embedFile("./data/markov.char");
  //     var loaded = try GenMarkov.initImmutableUncopyable(data, .{.allocator = allocator, .random = undefined});
  //     defer loaded.free(allocator);
  //
  //     const stats = comptime MarkovModelStats.fromBytes(data) catch unreachable;
  //     const model: *GenMarkov.GetMarkovGen(
  //       stats.key.Type(),
  //       stats.val.Type(),
  //       markovStats.EndianEnum.fromEndian(defaults.Endian)
  //     ) = @ptrCast(&loaded._data);
  //
  //     const keys_slice = model.generator.keys[0..model.generator.key_len];
  //     const vals_slice = model.generator.vals[0..model.generator.val_len];
  //
  //     getValidator(@TypeOf(makov.base).LENGTH, stats.key.Type(), stats.val.Type(), defaults.Endian)(makov, keys_slice, vals_slice);
  //   }
  // }
};

test TrainingImplementation {
  std.testing.refAllDecls(TrainingImplementation);
}

// WordMakovType to use for model generation
const WordMakovType = WordMakov(4);
// CharMakovType to use for model generation
const CharMakovType = CharMakov(8);

pub const main = TrainingImplementation.main;

