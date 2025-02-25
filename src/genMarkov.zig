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
  const MarkovType = GetMarkovGen(u0, u0, CpuEndianness);
  /// WARNING: Any operations on this field (without explicit knowledge of what you are doing)
  ///   are __unchecked__ illegal behaviour
  _data: MarkovType,
  vtable: *const Vtable,

  pub const Vtable = struct {
    gen: *const fn (*anyopaque) []const u8,
    roll: *const fn (*anyopaque) void,
    free: *const fn (*anyopaque, allocator: std.mem.Allocator) void,
    state: *const fn (*anyopaque) *StateStruct
  };

  pub fn gen(self: *@This()) []const u8 { return self.vtable.gen(@ptrCast(&self._data)); }
  pub fn roll(self: *@This()) void { self.vtable.roll(@ptrCast(&self._data)); }
  pub fn free(self: *@This(), allocator: std.mem.Allocator) void { self.vtable.free(@ptrCast(&self._data), allocator); }
  pub fn state(self: *@This()) *StateStruct { return self.vtable.state(@ptrCast(&self._data)); }
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
                    var oval = meta.readPackedStructEndian(T, bytes[from..][0..size], Endianness.toEndian());
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

pub fn GetMarkovGen(Key: type, Val: type, Endianness: Stats.EndianEnum) type {
  const read = struct {
    fn read(comptime T: type, slice: []const u8, index: usize) T {
      const size = (@bitSizeOf(T) + 7) >> 3;
      var oval = meta.readPackedStructEndian(T, slice[size*index..][0..size], Endianness.toEndian());
      if (CpuEndianness != Endianness) std.mem.byteSwapAllFields(@TypeOf(oval), &oval);
      return oval;
    }
  }.read;

  const TableKey = meta.TableKey(Key, Val);
  const TableVal = meta.TableVal(Key, Val);

  const sizeTableKey = (@bitSizeOf(TableKey) + 7) >> 3;
  const sizeTableVal = (@bitSizeOf(TableVal) + 7) >> 3;

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
      try table.append(@intCast(conv_table.len)); // Terminal entry

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
    freeable_slice: []const u8,

    const RetStruct = @This();

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

      fn printKey(self: *@This(), key: TableKey) void {
        if (Key == u8) {
          std.debug.print("({c:1}({d:3})", .{key.key, key.key});
        } else {
          const patent: *RetStruct = @fieldParentPtr("generator", self);
          std.debug.print("({s}", .{patent.converter.word.convert(key.key)});
        }

        std.debug.print(", .value = {d:8}, .next = {d:8})", .{key.value, key.next});
      }

      /// Generate a key, a key may or may not translate to a full word
      fn gen(self: *@This()) Key {
        const key0 = read(TableKey, self.keys[0..self.key_len], self.state.index);
        const key1 = read(TableKey, self.keys[0..self.key_len], self.state.index+1);
        const vals = self.vals[key0.value*sizeTableVal..key1.value*sizeTableVal];

        // std.debug.print("\nDATA: ", .{});
        // printKey(self, key0);
        // std.debug.print("\n", .{});
        // for (0..key1.value - key0.value) |index| {
        //   const val = read(TableVal, vals, index);
        //   const key = read(TableKey, self.keys[0..self.key_len], key0.next + val.subnext);
        //   std.debug.print("(.subnext = {d:8}, .val = {d:8}): ", .{val.subnext, val.val});
        //   printKey(self, key);
        //   std.debug.print("\n", .{});
        // }
        // std.debug.print("\n", .{});

        const last_val = read(TableVal, self.vals[0..self.val_len], key1.value-1).val;
        const Ctx = struct {
          vals: []const u8,
          target: Val,
          pub fn compareFn(ctx: @This(), idx: usize) std.math.Order {
            const v = read(TableVal, ctx.vals, idx);
            return std.math.order(ctx.target, v.val);
          }
        };

        const idx: u32 = blk: {
          if (key1.value - key0.value == 1) break :blk 0;

          const target = self.state.random.intRangeLessThan(Val, 0, last_val);

          const first_val = read(TableVal, vals, 0).val;
          if (target <= first_val) break :blk 0;
          if (key1.value - key0.value == 2) break :blk 1;

          const sort = @import("common/markov/sort.zig");
          const from, const to = sort.equalRange(1, vals.len / sizeTableVal, Ctx{.target = target, .vals = vals});
          if (from == to) break :blk @intCast(from);

          break :blk self.state.random.intRangeLessThan(u32, @intCast(from), @intCast(to));
        };

        const val = read(TableVal, vals, idx);
        self.state.index = key0.next + val.subnext;

        return key0.key;
      }

      pub fn roll(self: *@This()) void {
        self.state.index = self.state.random.intRangeLessThan(u32, 0, @divExact(self.key_len, sizeTableKey));
      }
    };

    fn initFragments(self: *@This(), keys: []const u8, vals: []const u8, convTable: ?[]const u8, options: InitOptions) !void {
      self.* = .{
        .generator = .{
          .keys = keys.ptr,
          .vals = vals.ptr,
          .key_len = @intCast(keys.len),
          .val_len = @intCast(vals.len),
          .state = .{
            .random = options.random,
            .index = 0,
          },
        },
        .converter = if (Key == u8) .{
          .char = try CharConverter.init(options.max_char_length, options.allocator),
        } else .{
          .word = try WordConverter.init(convTable.?, options.allocator),
        },
        .freeable_slice = options.allocation,
      };
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
      if (self.freeable_slice.len != 0) {
        allocator.free(self.freeable_slice);
      }

      if (Key == u8) {
        self.converter.char.deinit(allocator);
      } else {
        self.converter.word.deinit(allocator);
      }
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
        ._data = @as(*const AnyMarkovGen.MarkovType, @ptrCast(self)).*,
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

test "word_markov" {
  const allocator = std.testing.allocator;
  var data_dir = try std.fs.cwd().makeOpenPath("data", .{});
  defer data_dir.close();

  const data = try data_dir.readFileAlloc(allocator, "markov.word", std.math.maxInt(usize));
  var gen = initMutable(data, .{
    .random = @import("common/rng.zig").getRandom(),
    .allocator = allocator,
    .allocation = data
  }) catch |e| {
    allocator.free(data);
    return e;
  };
  defer gen.free(allocator);
  // gen.roll();

  std.debug.print("\nWord Markov:", .{});
  for (0..1024) |_| {
    const word = gen.gen();
    std.debug.print(" {s}", .{word});
  }
  std.debug.print("\n", .{});
}

test "char_markov" {
  const allocator = std.testing.allocator;
  var data_dir = try std.fs.cwd().makeOpenPath("data", .{});
  defer data_dir.close();

  const data = try data_dir.readFileAlloc(allocator, "markov.char", std.math.maxInt(usize));
  var gen = initMutable(data, .{
    .random = @import("common/rng.zig").getRandom(),
    .allocator = allocator,
    .allocation = data
  }) catch |e| {
    allocator.free(data);
    return e;
  };
  defer gen.free(allocator);
  // gen.roll();

  std.debug.print("\nChar Markov:", .{});
  for (0..1024) |_| {
    const word = gen.gen();
    std.debug.print(" {s}", .{word});
  }
  std.debug.print("\n", .{});
}

