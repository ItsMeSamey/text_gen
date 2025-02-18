const std = @import("std");
const Stats = @import("common/markov/markovStats.zig");
const meta = @import("common/markov/meta.zig");

const CpuEndianness = Stats.EndianEnum.fromEndian(@import("builtin").cpu.arch.endian());

/// These are the values that define the state of the generator
/// You can get the generator to behave deterministicaly by restoring these values only
pub const StateStruct = struct {
  index: u32,
  random: std.Random,
};

pub const AnyMarkovGen = struct {
  data: [@sizeOf(GetMarkovGen(u0, u0, CpuEndianness))]u8,
  vtable: *const Vtable,

  pub const Vtable = struct {
    gen: *const fn (*anyopaque) []const u8,
    roll: *const fn (*anyopaque) void,
    free: *const fn (*anyopaque, allocator: std.mem.Allocator) void,
    state: *const fn (*anyopaque) *StateStruct
  };

  fn gen(self: *@This()) []const u8 { return self.vtable.gen(@ptrCast(@alignCast(&self.data))); }
  fn roll(self: *@This()) void { self.vtable.roll(@ptrCast(@alignCast(&self.data))); }
  fn free(self: *@This(), allocator: std.mem.Allocator) void { self.vtable.free(@ptrCast(@alignCast(&self.data)), allocator); }
  fn state(self: *@This()) *StateStruct { return self.vtable.state(@ptrCast(@alignCast(&self.data))); }
};

fn statsWithSameEndianness(data: []const u8) Stats {
  var stats = Stats.ModelStats.fromBytes(data);
  stats.endian = CpuEndianness;
  return stats;
}

fn readOne(comptime T: type, Endianness: Stats.EndianEnum, data: []const u8, offset: usize) T {
  var retval: [1]T = .{@bitCast(data[offset..][0..@sizeOf(T)].*)};
  if (CpuEndianness != Endianness) std.mem.byteSwapAllFields([1]T, &retval);
  return retval[0];
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

pub const InitOptions = struct {
  /// The allocator to use for internal allocations
  /// This same allocatior needs to be provided when calling `AnyMarkovGen.free()`
  allocator: std.mem.Allocator,

  /// The random device to be used for text generation
  random: std.Random,

  /// The allocation that should be freed by the allocator on object cleanup (the file you read from disk)
  /// Can only be set in call to mutable, otherwise initialization will PANIC!
  /// NOTE: if length of this field is 0, the allocation will not be freed (even if you set this manually)
  allocation: []const u8 = blk: {
    var val: []const u8 = undefined;
    val.ptr = @ptrFromInt(1);
    val.len = 0;
    break :blk val;
  },

  /// NOTE: This is used in chat model only, ignored for word model
  /// If a word exceeds this length, it will be clipped
  max_char_length: u32 = 256,
};

/// Has no runtiume cost when endianness does not match as it mutates data to change the endianness in place
/// Mutates the header too to reflect the change
pub fn initMutable(data: []u8, options: InitOptions) !AnyMarkovGen {
  return getMarkovGenInterface(.mutable, data, options);
}


/// NOTE: I have not seen any valid use case of immutable_copyable, it's probably a sign of a deeper problem, use `initMutable` or `initImmutableUncopyable` instead
/// If endianness is not the same as native, this will copy the data, data is freed on call to free
/// This allocates slightly less memory than the size of the whole data, but in case of a word model
///   it copies a lot less (specifically does not copy the conversion table)
pub fn initImmutableCopyable(data: []const u8, options: InitOptions) !AnyMarkovGen {
  if (@inComptime()) {
    if (options.allocation.len != 0) @compileError("Cannot set options.allocation in call to initImmutableCopyable()");
  } else {
    if (options.allocation.len != 0) @panic("Cannot set options.allocation in call to initImmutableCopyable()");
  }
  return getMarkovGenInterface(.immutable_copyable, data, options);
}

/// This may have runtime cost of interchanging endianness if a model with opposite endianness is loaded
pub fn initImmutableUncopyable(data: []const u8, options: InitOptions) !AnyMarkovGen {
  if (@inComptime()) {
    if (options.allocation.len != 0) @compileError("Cannot set options.allocation in call to initImmutableUncopyable()");
  } else {
    if (options.allocation.len != 0) @panic("Cannot set options.allocation in call to initImmutableUncopyable()");
  }
  return getMarkovGenInterface(.immutable_uncopyable, data, options);
}

/// Read the packed struct from an packed array of structs
fn readPackedStruct(comptime T: type, ptr: []const u8, index: usize) T {
  const size = (@bitSizeOf(T) + 7) >> 3;
  const oval_bits = ptr[index*size..][0..size];
  var oval: T = undefined;
  @memcpy(std.mem.asBytes(&oval)[0..size], oval_bits);
  @memset(std.mem.asBytes(&oval)[size..], 0);
  return oval;
}

const InitType = enum {
  mutable,
  immutable_copyable,
  immutable_uncopyable,
};

fn getMarkovGenInterface(comptime init: InitType, data: []const u8, immutable_options: InitOptions) !AnyMarkovGen {
  const stats = try Stats.ModelStats.fromBytes(data);
  const offsets = try getOffsetsFromData(stats, data);

  var keys = data[offsets.keys.start..offsets.keys.end];
  var vals = data[offsets.vals.start..offsets.vals.end];
  var options = immutable_options;

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
              // Endianness now comptime
              const swapEndianness = struct {
                fn swapEndiannessPackedSlice(comptime T: type, bytes: []u8) void {
                  const size = (@bitSizeOf(T) + 7) >> 3;
                  std.debug.assert(@rem(bytes.len, size) == 0);
                  var from: usize = 0;
                  while (from < bytes.len): (from += size) {
                    var oval = readPackedStruct(T, bytes, from);
                    std.mem.byteSwapAllFields(@TypeOf(oval), &oval);
                    @memcpy(bytes[from..][0..size], std.mem.asBytes(&oval)[0..size]);
                  }
                }

                fn swapEndianness(keySlice: []u8, valSlice: []u8) void {
                  swapEndiannessPackedSlice(TableKey, keySlice);
                  swapEndiannessPackedSlice(TableVal, valSlice);
                }
              }.swapEndianness;

              // All of the switch cases here are (or atleast are supposed to be) comptime
              const Model = GetMarkovGen(Key, Val, if (Endianness != CpuEndianness and init == .immutable_uncopyable) Endianness else CpuEndianness);

              var model: Model = undefined;
              if (Endianness != CpuEndianness) {
                if (init == .mutable) {
                  swapEndianness(@constCast(keys), @constCast(vals));
                } else if (init == .immutable_copyable) {
                  const freeableSliceSize = keys.len + vals.len;
                  const freeableSlice: []u8 = try options.allocator.alloc(u8, freeableSliceSize);
                  const mutableKeys = freeableSlice[0..keys.len];
                  const mutableVals = freeableSlice[keys.len..][0..vals.len];
                  @memcpy(mutableKeys, keys);
                  @memcpy(mutableVals, vals);
                  swapEndianness(mutableKeys, mutableVals);
                  options.allocation = freeableSlice;
                  keys = mutableKeys;
                  vals = mutableVals;
                }
              }
              try model.initFragments(keys, vals, convTable, options);

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
      var oval = readPackedStruct(T, slice, index);
      if (CpuEndianness != Endianness) std.mem.byteSwapAllFields(@TypeOf(oval), &oval);
      return oval;
    }
  }.read;

  const TableKey = meta.TableKey(Key, Val);
  const TableVal = meta.TableVal(Key, Val);

  // key generator
  const Generator = struct {
    /// The state of this generator
    state: StateStruct,

    /// pointer to table of keys
    keys: [*]const u8,
    /// pointer to table of values to the keys
    vals: [*]const u8,

    /// Table of keys length
    key_len: u32,
    /// Table of values length
    val_len: u32,

    /// Generate a key, a key may or may not translate to a full word
    fn gen(self: *@This()) Key {
      const key0 = read(TableKey, self.keys[0..self.key_len], self.state.index);
      const key1 = read(TableKey, self.keys[0..self.key_len], self.state.index+1);

      const from, const to = @import("common/markov/sort.zig").equalRange(key0.value, key1.value,
        struct {
          target: usize,
          vals: []const u8,
          pub fn compareFn(ctx: @This(), idx: usize) std.math.Order {
            const v = read(TableVal, ctx.vals, idx);
            return std.math.order(v.val, ctx.target);
          }
        }{
          .target = self.state.random.intRangeLessThan(usize, key0.value, key1.value),
          .vals = self.vals[0..self.val_len],
        }
      );

      const val = read(TableVal, self.vals[0..self.val_len], if (from == to) @intCast(from)
        else self.state.random.intRangeLessThan(@TypeOf(self.state.index), @intCast(from), @intCast(to)));
      self.state.index = @intCast(key0.next + val.subnext);

      return key0.key;
    }

    pub fn roll(self: *@This()) void {
      self.state.index = self.state.random.intRangeLessThan(@TypeOf(self.state.index), 0, self.key_len);
    }
  };

  const CharConverter = struct {
    buffer: [*]u8,
    buffer_capacity: u32,
    buffer_at: u32,

    pub fn init(buffer_capacity: u32, allocator: std.mem.Allocator) !@This() {
      return .{
        .buffer = (try allocator.alloc(u8, buffer_capacity)).ptr,
        .buffer_capacity = buffer_capacity,
        .buffer_at = 0,
      };
    }

    fn convert(self: *@This(), input: u8) ?[]const u8 {
      if (input == '\x00') {
        defer self.buffer_at = 0;
        return self.buffer[0..self.buffer_at];
      }

      self.buffer[self.buffer_at] = input;
      self.buffer_at += 1;
      return null;
    }

    fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
      allocator.free(self.buffer[0..self.buffer_capacity]);
    }
  };

  const WordConverter = struct {
    conv_table: [*]const u8,
    table: [*]const u32,
    table_len: u32,

    fn init(conv_table: []const u8, allocator: std.mem.Allocator) !@This() {
      var table = std.ArrayList(u32).init(allocator);
      errdefer table.deinit();

      var i: u32 = 0;
      while (i < conv_table.len) {
        try table.append(i);
        while (conv_table[i] != '\x00') i += 1;
        i += 1;
      }
      try table.append(@intCast(conv_table.len + 1)); // Extra terminal entry

      const table_slice = try table.toOwnedSlice();

      return .{
        .conv_table = conv_table.ptr,
        .table = table_slice.ptr,
        .table_len = @intCast(table_slice.len),
      };
    }

    fn convert(self: *const @This(), input: Key) []const u8 {
      const table = self.table[0..self.table_len];
      return self.conv_table[table[input]..table[@as(usize, input) + 1] - 1];
    }

    fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
      allocator.free(self.table[0..self.table_len]);
    }
  };

  return struct {
    generator: Generator,
    converter: union{ char: CharConverter, word: WordConverter },

    fn initFragments(self: *@This(), keys: []const u8, vals: []const u8, convTable: ?[]const u8, options: InitOptions) !void {
      self.* = .{
        .generator = .{
          .keys = keys.ptr,
          .vals = vals.ptr,
          .key_len = @intCast(keys.len),
          .val_len = @intCast(vals.len),
          .state = .{
            .random = options.random,
            .index = @intCast(options.random.intRangeLessThan(usize, 0, keys.len))
          },
        },
        .converter = if (Key == u8) .{
          .char = try CharConverter.init(options.max_char_length, options.allocator),
        } else .{
          .word = try WordConverter.init(convTable.?, options.allocator),
        },
      };

      if (Key == u8) {
        _ = self.gen();
      }
    }

    pub fn gen(self: *@This()) []const u8 {
      if (Key == u8) {
        while (true) {
          if (self.converter.char.convert(self.generator.gen())) |retval| return retval;
        }
      } else {
        return self.converter.word.convert(self.generator.gen());
      }
    }

    pub fn roll(self: *@This()) void {
      self.generator.roll();
    }

    pub fn free(self: *@This(), allocator: std.mem.Allocator) void {
      if (Key != u8) { self.converter.word.deinit(allocator); }
    }

    pub fn state(self: *@This()) *StateStruct {
      return &self.generator.state;
    }

    pub fn any(self: *@This()) AnyMarkovGen {
      const Self = @This();
      const Adapter = struct {
        pub fn gen(ptr: *anyopaque) []const u8 { return Self.gen(@ptrCast(@alignCast(ptr))); }
        pub fn roll(ptr: *anyopaque) void { return Self.roll(@ptrCast(@alignCast(ptr))); }
        pub fn free(ptr: *anyopaque, allocator: std.mem.Allocator) void { return Self.free(@ptrCast(@alignCast(ptr)), allocator); }
        pub fn state(ptr: *anyopaque) *StateStruct { return &@as(*Self, @ptrCast(@alignCast(ptr))).generator.state; }
        pub fn dupe(ptr: *anyopaque) *usize { return &@as(*Self, @ptrCast(@alignCast(ptr))).generator.state; }
      };

      return .{
        .data = std.mem.asBytes(self).*,
        .vtable = &AnyMarkovGen.Vtable{
          .gen = Adapter.gen,
          .roll = Adapter.roll,
          .free = Adapter.free,
          .state = Adapter.state,
        },
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
  var gen = try initMutable(data, .{
    .random = @import("common/rng.zig").getRandom(),
    .allocator = allocator,
    .allocation = data
  });
  defer gen.free(std.testing.allocator);

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
  var gen = try initMutable(data, .{
    .random = @import("common/rng.zig").getRandom(),
    .allocator = allocator,
    .allocation = data
  });
  defer gen.free(std.testing.allocator);

  std.debug.print("\nWord Markov:", .{});
  for (0..1024) |_| {
    const word = gen.gen();
    std.debug.print(" {s}", .{word});
  }
  std.debug.print("\n", .{});
}

