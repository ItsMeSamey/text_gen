test { std.testing.refAllDeclsRecursive(@This()); }
const std = @import("std");
const Stats = @import("common/markov/markovStats.zig");
const meta = @import("common/markov/meta.zig");

const GenInterface = @import("genInterface.zig");

const CpuEndianness = Stats.EndianEnum.fromEndian(@import("builtin").cpu.arch.endian());

fn statsWithSameEndianness(data: []const u8) Stats {
  var stats = Stats.ModelStats.fromBytes(data);
  stats.endian = CpuEndianness;
  return stats;
}

fn readOne(comptime T: type, Endianness: Stats.EndianEnum, data: []const u8, offset: usize) T {
  var retval: [1]T = data[offset][0..@sizeOf(T)];
  comptime if (CpuEndianness != Endianness) std.mem.byteSwapAllFields(std.meta.Child(@TypeOf(data)), &retval);
  return retval;
}

const Offsets = struct {
  keys: Stats.Range,
  vals: Stats.Range,
  chainArray: Stats.Range,
  conversionTable: ?Stats.Range,
};

/// Get offsets of specific sections in a file
fn getOffsetsFromData(data: []const u8) Offsets {
  var retval: Offsets = undefined;

  const loader = struct {
    d: @TypeOf(data),
    fn load(self: *@This()) Stats.Range {
      const r = Stats.Range{ .start = readOne(u64, self.d, self.d.len - @sizeOf(u64)), .end = self.d.len - @sizeOf(u64)};
      self.d = self.d[0..self.d.len - r.start - @sizeOf(u64)];
    }
  }{ .d = data };
  const load = loader.load;

  const stats = Stats.ModelStats.fromBytes(data);
  if (stats.key == .u8) {
    retval.conversionTable = null;
  } else {
    retval.conversionTable = load();
  }

  retval.chainArray = loader.load();
  retval.vals = loader.load();
  retval.keys = loader.load();
  return retval;
}

/// Has no runtiume cost when endianness does not match as it mutates data to change the endianness in place
/// Mutates the header too to reflect the change
pub fn initMutable(data: []u8, allocator: std.mem.Allocator) !GenInterface.WordGenerator {
  const Model = GetMarkovGenFromRuntimeStats(Stats.ModelStats.fromBytes(data));
  return GenInterface.fromGenMarkov(Model.initMutable(data, allocator));
}

/// This may have runtime cost of interchanging endianness if a model with inappropriate endianness is loaded
pub fn initImmutableCopyable(data: []const u8, allocator: std.mem.Allocator) !GenInterface.WordGenerator {
  const stats = Stats.ModelStats.fromBytes(data);
  if (CpuEndianness == stats.endian) return initImmutableUncopyable(data, allocator);

  const copy = try allocator.alloc(u8, data.len);
  @memcpy(copy, data);

  return initMutable(copy, allocator);
}

pub fn initImmutableUncopyable(data: []const u8, allocator: std.mem.Allocator) !GenInterface.WordGenerator {
  const offsets = getOffsetsFromData(data);
  const Model = GetMarkovGenFromRuntimeStats(Stats.ModelStats.fromBytes(data));
  const carray = allocator.alloc(u8, offsets.chainArray.end - offsets.chainArray.start);
  @memcpy(carray, data[offsets.chainArray.start..offsets.chainArray.end]);

  return GenInterface.fromGenMarkov(Model.init(data, carray, true, allocator));
}

fn GetMarkovGenFromRuntimeStats(stats: Stats) type {
  // Has 4 * 2 * 2 = 16 branches
  switch (stats.key) {
    inline .u8, .u16, .u32, .u64 => |K| {
      // K now comptime
      const Key: type = Stats.KeyEnum.Type(K);
      switch (stats.val) {
        inline .f32, .f64 => |V| {
          // V now comptime
          const Val: type = Stats.ValEnum.Type(V);
          switch (stats.endian) {
            inline .little, .big => |Endianness| {
              // Endianness now comptime
              return GetMarkovGen(Key, Val, Endianness);
            } 
          }
        }
      }
    }
  }
}

fn GetMarkovGen(Key: type, Val: type, Endianness: Stats.EndianEnum, ConversionContext: type) type {
  const fnType = @TypeOf(ConversionContext.convert);
  comptime std.debug.assert(fnType == fn (self: *ConversionContext, index: u32) ?[]const u8);

  const read = struct {
    fn read(comptime Output: type, data: [*]const u8, index: usize) Output {
      var retval = data[@sizeOf(Output) * index][0 .. @sizeOf(Output)];
      comptime if (CpuEndianness != Endianness) std.mem.byteSwapAllFields(std.meta.Child(@TypeOf(data)), &retval);
      return retval;
    }
  }.read;

  const TableKey = meta.TableKey(Key, Val);
  const TableVal = meta.TableVal(Key, Val);
  const TableChain = meta.TableChain(Key, Val);

  // key generator
  const Generator = struct {
    /// table of keys
    keys: [*]const u8,
    /// table of values to the keys
    vals: [*]const u8,
    /// an array of saperate chain offsets inside of the `jt` and is again the result of `Base.flush`
    carray: [*]u8,

    keyCount: u32,
    valCount: u32,

    carrayCount: u32,
    /// index of the chain that is currently selected
    cindex: u32,

    // The random number generator
    random: std.Random,

    const Self = @This();

    /// Generate a key, a key may or may not translate to a full word
    fn gen(self: *const Self) Key {
      const offset = self.carray[self.cindex].offset;
      const key0 = read(TableKey, self.keys, offset);
      const key1 = read(TableKey, self.keys, offset+1);

      const target = self.random.float(Val);
      var start: usize = key0.value;
      var end: usize = key1.value;
      var mid: usize = undefined;

      while (start < end) {
        mid = (end - start) / 2;
        const midVal = read(TableVal, self.vals, mid);

        if (target < midVal.val) {
          end = mid;
        } else {
          start = mid + 1;
        }
      }

      const keyNext = read(TableKey, self.vals, mid);
      self.carray[self.cindex].offset = key0.next + keyNext.subnext;

      return key0.key;
    }

    /// Refresh the cindex to random
    pub fn roll(self: *Self) void {
      var start: u32 = 0;
      var end: u32 = self.carrayCount;
      var mid: u32 = undefined;

      while (start < end) {
        mid = (end - start) / 2;
        const midVal = read(TableChain, self.carray, mid);
        if (midVal.offset < self.cindex) {
          start = mid + 1;
        } else {
          end = mid;
        }
      }

      self.cindex = mid;
    }
  };

  const Converter = if (Key == u8) struct {
    buffer: [256]u8,
    present: u8,

    fn convert(self: *@This(), input: Key) ?[]const u8 {
      if (input == '\x00') return self.buffer[0..self.present];

      self.buffer[self.present] = input;
      self.present += 1;
      return null;
    }
  } else struct {
    table: []const u32,

    fn init(convTable: []const u8, allocator: std.mem.Allocator) !@This() {
      var table = std.ArrayList(u32).init(allocator);
      errdefer table.deinit();

      for (convTable, 0..) |char, i| {
        if (char == '\x00') try table.append(@intCast(i));
      }

      return .{
        .table = try table.toOwnedSlice()
      };
    }

    fn convert(self: *const @This(), input: Key) []const u8 {
      return self.table[input];
    }

    fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
      allocator.free(self.table);
    }
  };

  return struct {
    generator: Generator,
    converter: Converter,
    /// Allocator for convTable and possibly carray
    allocator: std.mem.Allocator,
    
    const Self = @This();

    /// init this struct
    /// NOTE: we try to automatically free `carray` if it is not contained in data
    fn init(data: []const u8, carray: []u8, allocator: std.mem.Allocator) !Self {
      const offsets = getOffsetsFromData(data);

      return Self.initFragments(
        data[offsets.keys.start..offsets.keys.end],
        data[offsets.vals.start..offsets.vals.end],
        carray,
        allocator,
      );
    }

    fn initMutable(data: []u8, allocator: std.mem.Allocator) !Self {
      const offsets = getOffsetsFromData(data);

      return Self.initFragments(
        data[offsets.keys.start..offsets.keys.end],
        data[offsets.vals.start..offsets.vals.end],
        data[offsets.chainArray.start..offsets.chainArray.end],
        false,
        allocator,
      );
    }

    fn initFragmentsMutable(keys: []u8, vals: []u8, carray: []u8, allocator: std.mem.Allocator) !Self {
      return Self.initFragments(keys, vals, carray, allocator);
    }

    fn initFragments(keys: []const u8, vals: []const u8, carray: []u8, allocator: std.mem.Allocator) !Self {
      return .{
        .generator = .{
          .keys = keys.ptr,
          .vals = vals.ptr,
          .carray = carray.ptr,
          .keyCount = keys.len / @sizeOf(TableKey),
          .valCount = vals.len / @sizeOf(TableVal),
          .carrayCount = carray.len / @sizeOf(TableChain),
          .cindex = 0,
          .random = @import("common/rng.zig").getRandom(),
        },
        .converter = if (Key == u8) .{
          .buffer = undefined,
          .present = 0,
        } else try Converter.init(),
        .allocator = allocator,
      };
    }

    pub fn gen(self: *Self) []const u8 {
      if (Key == u8) {
        while (true) { if (self.converter.convert(self.generator.gen())) |retval| return retval; }
      }
      return self.converter.convert(self.generator.gen());
    }

    pub fn roll(self: *Self) void {
      self.generator.roll();
    }

    pub fn deinit(self: *Self) void {
      if (Key == u8) {
        self.converter.deinit(self.allocator);
      }
    }
  };
}

