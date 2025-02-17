const std = @import("std");
const Stats = @import("common/markov/markovStats.zig");
const meta = @import("common/markov/meta.zig");
const sort = @import("common/sort.zig");

const CpuEndianness = Stats.EndianEnum.fromEndian(@import("builtin").cpu.arch.endian());

fn statsWithSameEndianness(data: []const u8) Stats {
  var stats = Stats.ModelStats.fromBytes(data);
  stats.endian = CpuEndianness;
  return stats;
}

fn readOne(comptime T: type, Endianness: Stats.EndianEnum, data: []const u8, offset: usize) T {
  var retval: T = @bitCast(data[offset..][0..@sizeOf(T)].*);
  if (CpuEndianness != Endianness) meta.swapEndianness(&retval);
  return retval;
}

const Offsets = struct {
  keys: Stats.Range,
  vals: Stats.Range,
  conversionTable: ?Stats.Range,
};

/// Get offsets of specific sections in a file
fn getOffsetsFromData(stats: Stats.ModelStats, data: []const u8) !Offsets {
  var retval: Offsets = undefined;

  var loader = struct {
    d: @TypeOf(data),
    stats: Stats.ModelStats,
    pub fn load(self: *@This()) Stats.Range {
      const len: u64 = readOne(u64, self.stats.endian, self.d, self.d.len - @sizeOf(u64));
      self.d.len -= len + @sizeOf(u64);
      const r = Stats.Range{ .start = self.d.len, .end = self.d.len + len };
      return r;
    }
  }{
    .d = data,
    .stats = stats,
  };

  if (stats.key == .u8) {
    retval.conversionTable = null;
  } else {
    retval.conversionTable = loader.load();
  }

  retval.vals = loader.load();
  retval.keys = loader.load();

  return retval;
}

pub const AnyMarkovGen = struct {
  ptr: *anyopaque,
  _gen: *const fn (*anyopaque) []const u8,
  _roll: *const fn (*anyopaque) void,
  _free: *const fn (*anyopaque) void,
  _state: *const fn (*anyopaque) usize,

  fn gen(self: *const @This()) []const u8 { return self._gen(self.ptr); }
  fn roll(self: *const @This()) void { self._roll(self.ptr); }
  fn free(self: *const @This()) void { self._free(self.ptr); }
  fn state(self: *const @This()) usize { return self._state(self.ptr); }
};

/// Has no runtiume cost when endianness does not match as it mutates data to change the endianness in place
/// Mutates the header too to reflect the change
pub fn initMutable(data: []u8, allocator: std.mem.Allocator) !AnyMarkovGen {
  return getMarkovGenInterface(.mutable, data, allocator);
}

/// If endianness is not the same as native, this will copy the data, data is freed on call to free
/// This allocates slightly less memory than the size of the whole data, but in case of a word model
///   it copies a lot less (specifically does not copy the conversion table)
pub fn initImmutableCopyable(data: []const u8, allocator: std.mem.Allocator) !AnyMarkovGen {
  return getMarkovGenInterface(.immutable_copyable, data, allocator);
}

/// This may have runtime cost of interchanging endianness if a model with inappropriate endianness is loaded
pub fn initImmutableUncopyable(data: []const u8, allocator: std.mem.Allocator) !AnyMarkovGen {
  return getMarkovGenInterface(.immutable_uncopyable, data, allocator);
}

const InitType = enum {
  mutable,
  immutable_copyable,
  immutable_uncopyable,
};

fn getMarkovGenInterface(comptime init: InitType, data: []const u8, allocator: std.mem.Allocator) !AnyMarkovGen {
  const stats = try Stats.ModelStats.fromBytes(data);
  const offsets = try getOffsetsFromData(stats, data);

  const keys = data[offsets.keys.start..offsets.keys.end];
  const vals = data[offsets.vals.start..offsets.vals.end];

  const convTable = if (offsets.conversionTable) |convTable| data[convTable.start..convTable.end] else null;

  // Has 4 * 2 * 2 = 16 branches
  switch (stats.key) {
    inline .u8, .u16, .u24, .u32 => |K| {
      // K now comptime
      const Key: type = Stats.KeyEnum.Type(K);
      switch (stats.val) {
        inline .u16, .u32 => |V| {
          // V now comptime
          const Val: type = Stats.ValEnum.Type(V);
          const TableKey = meta.TableKey(Key, Val);
          const TableVal = meta.TableVal(Key, Val);

          std.debug.assert(@rem(keys.len, (@bitSizeOf(TableKey) + 7) >> 3) == 0);
          std.debug.assert(@rem(vals.len, (@bitSizeOf(TableVal) + 7) >> 3) == 0);

          switch (stats.endian) {
            inline .little, .big => |Endianness| {
              const swapEndianness = struct {
                fn swapEndianness(keySlice: []u8, valSlice: []u8) void {
                  meta.swapEndianness(@as([*]TableKey, @alignCast(@ptrCast(keySlice.ptr)))[0..keySlice.len/@sizeOf(Key)]);
                  meta.swapEndianness(@as([*]TableVal, @alignCast(@ptrCast(valSlice.ptr)))[0..valSlice.len/@sizeOf(Val)]);
                }
              }.swapEndianness;
              // Endianness now comptime

              // All of the switch cases here are (or atleast are supposed to be) comptime
              const Model = GetMarkovGen(Key, Val, if (Endianness != CpuEndianness and init == .immutable_uncopyable) Endianness else CpuEndianness);
              const freeableSliceSize = @sizeOf(Model) + (if (Endianness != CpuEndianness and init == .immutable_copyable) keys.len + vals.len else 0);
              const freeableSlice = try allocator.alignedAlloc(u8, @alignOf(Model), freeableSliceSize);

              var model: *Model = @ptrCast(freeableSlice[0..@sizeOf(Model)].ptr);
              if (Endianness == CpuEndianness) {
                try model.initFragments(keys, vals, convTable, allocator, freeableSliceSize);
              } else {
                switch (init) {
                  .mutable => {
                    const mutableKeys = @constCast(keys);
                    const mutableVals = @constCast(vals);
                    swapEndianness(mutableKeys, mutableVals);
                    try model.initFragments(mutableKeys, mutableVals, convTable, allocator, freeableSliceSize);
                  },
                  .immutable_copyable => {
                    const mutableKeys = freeableSlice[@sizeOf(Model)..][0..keys.len];
                    const mutableVals = mutableKeys.ptr[keys.len..][0..vals.len];
                    @memcpy(mutableKeys, keys);
                    @memcpy(mutableVals, vals);
                    swapEndianness(mutableKeys, mutableVals);
                    try model.initFragments(mutableKeys, mutableVals, convTable, allocator, freeableSliceSize);
                  },
                  .immutable_uncopyable => {
                    try model.initFragments(keys, vals, convTable, allocator, freeableSliceSize);
                  },
                }
              }

              return model.any();
            } 
          }
        }
      }
    }
  }
}

fn GetMarkovGen(Key: type, Val: type, Endianness: Stats.EndianEnum) type {
  const read = struct {
    fn read(comptime T: type, slice: []const u8, index: usize) T {
      const size = (@bitSizeOf(T) + 7) >> 3;
      const oval_bits = slice[index*size..][0..size];
      var oval: T = undefined;
      @memcpy(std.mem.asBytes(&oval)[0..size], oval_bits);
      @memset(std.mem.asBytes(&oval)[size..], 0);
      if (CpuEndianness != Endianness) std.mem.byteSwapAllFields(@TypeOf(oval), &oval);
      return oval;
    }
  }.read;

  const TableKey = meta.TableKey(Key, Val);
  const TableVal = meta.TableVal(Key, Val);

  // key generator
  const Generator = struct {
    /// table of keys
    keys: []const u8,
    /// table of values to the keys
    vals: []const u8,

    /// index in the keys table
    keyIndex: usize,

    /// The random number generator
    random: std.Random,

    /// Generate a key, a key may or may not translate to a full word
    fn gen(self: *@This()) Key {
      const key0 = read(TableKey, self.keys, self.keyIndex);
      const key1 = read(TableKey, self.keys, self.keyIndex+1);

      const from, const to = sort.equalRange(key0.value, key1.value,
        struct {
          target: usize,
          vals: []const u8,
          pub fn compareFn(ctx: @This(), idx: usize) std.math.Order {
            const v = read(TableVal, ctx.vals, idx);
            return std.math.order(v.val, ctx.target);
          }
        }{
          .target = self.random.intRangeLessThan(usize, key0.value, key1.value),
          .vals = self.vals,
        }
      );

      const val = read(TableVal, self.vals, if (from == to) from else self.random.intRangeLessThan(usize, from, to));
      self.keyIndex = @intCast(key0.next + val.subnext);

      return key0.key;
    }

    /// Refresh the cindex to random
    pub fn roll(self: *@This()) void {
      self.keyIndex = self.random.intRangeLessThan(usize, 0, self.keys.len);
    }
  };

  const Converter = if (Key == u8) struct {
    buffer: [256]u8,
    present: u8,

    fn convert(self: *@This(), input: u8) ?[]const u8 {
      if (input == '\x00') {
        defer self.present = 0;
        return self.buffer[0..self.present];
      }

      self.buffer[self.present] = input;
      self.present += 1;
      return null;
    }
  } else struct {
    convTable: [*]const u8,
    table: []const u32,

    fn init(convTable: []const u8, allocator: std.mem.Allocator) !@This() {
      var table = std.ArrayList(u32).init(allocator);
      errdefer table.deinit();

      var i: u32 = 0;
      while (i < convTable.len) {
        try table.append(i);
        while (convTable[i] != '\x00') i += 1;
        i += 1;
      }
      try table.append(@intCast(convTable.len + 1));

      return .{
        .convTable = convTable.ptr,
        .table = try table.toOwnedSlice(),
      };
    }

    fn convert(self: *const @This(), input: Key) []const u8 {
      return self.convTable[self.table[input]..self.table[@as(usize, input) + 1]-1];
    }

    fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
      allocator.free(self.table);
    }
  };

  return struct {
    generator: Generator,
    converter: Converter,
    /// Allocator for freeableSlice
    allocator: std.mem.Allocator,
    freeableSliceSize: usize,
    
    fn initFragments(self: *@This(), keys: []const u8, vals: []const u8, convTable: ?[]const u8, allocator: std.mem.Allocator, freeableSliceSize: usize) !void {
      self.* = .{
        .generator = .{
          .keys = keys,
          .vals = vals,
          .keyIndex = 0,
          .random = @import("common/rng.zig").getRandom(),
        },
        .converter = if (Key == u8) .{
          .buffer = undefined,
          .present = 0,
        } else try Converter.init(convTable.?, allocator),
        .allocator = allocator,
        .freeableSliceSize = freeableSliceSize,
      };

      if (Key == u8) {
        _ = self.gen();
      }
    }

    pub fn gen(self: *@This()) []const u8 {
      if (Key == u8) {
        while (true) {
          if (self.converter.convert(self.generator.gen())) |retval| return retval;
        }
      }
      return self.converter.convert(self.generator.gen());
    }

    pub fn roll(self: *@This()) void {
      self.generator.roll();
    }

    pub fn free(self: *@This()) void {
      if (Key != u8) {
        self.converter.deinit(self.allocator);
      }
      const memory: [*]align(@alignOf(@This())) u8 = @ptrCast(self);

      // IDK why, but freeing normally causes "General protection exception (no address available)"
      @call(std.builtin.CallModifier.auto, std.mem.Allocator.free, .{self.allocator, memory[0..self.freeableSliceSize]});
    }

    pub fn any(self: *@This()) AnyMarkovGen {
      const Self = @This();
      const Adapter = struct {
        pub fn _gen(ptr: *anyopaque) []const u8 { return gen(@ptrCast(@alignCast(ptr))); }
        pub fn _roll(ptr: *anyopaque) void { return roll(@ptrCast(@alignCast(ptr))); }
        pub fn _free(ptr: *anyopaque) void { return free(@ptrCast(@alignCast(ptr))); }
        pub fn _state(ptr: *anyopaque) usize { return @as(*Self, @ptrCast(@alignCast(ptr))).generator.keyIndex; }
      };

      return .{
        .ptr = @ptrCast(self),
        ._gen = Adapter._gen,
        ._roll = Adapter._roll,
        ._free = Adapter._free,
        ._state = Adapter._state,
      };
    }
  };
}

test {
  std.testing.refAllDecls(@This());
}

test "char_markov" {
  const allocator = std.testing.allocator;
  var data_dir = try std.fs.cwd().makeOpenPath("data", .{});
  defer data_dir.close();

  const data = try data_dir.readFileAlloc(allocator, "markov.char", std.math.maxInt(usize));
  defer allocator.free(data);

  var gen = try initMutable(data, allocator);
  defer gen.free();

  std.debug.print("\nChar Markov:", .{});
  for (0..1024) |_| {
    const word = gen.gen();
    std.debug.print(" {s}", .{word});
  }
  std.debug.print("\n", .{});
}

test "word_markov" {
  const allocator = std.testing.allocator;
  var data_dir = try std.fs.cwd().makeOpenPath("data", .{});
  defer data_dir.close();

  const data = try data_dir.readFileAlloc(allocator, "markov.word", std.math.maxInt(usize));
  defer allocator.free(data);

  var gen = try initMutable(data, allocator);
  defer gen.free();

  std.debug.print("\nWord Markov:", .{});
  for (0..1024) |_| {
    const word = gen.gen();
    std.debug.print(" {s}", .{word});
  }
  std.debug.print("\n", .{});
}

