const std = @import("std");
const Stats = @import("common/markov/markovStats.zig");
const meta = @import("common/markov/meta.zig");

const CpuEndianness = Stats.EndianEnum.fromEndian(@import("builtin").cpu.arch.endian());

fn statsWithSameEndianness(data: []const u8) Stats {
  var stats = Stats.ModelStats.fromBytes(data);
  stats.endian = CpuEndianness;
  return stats;
}

pub fn swapEndianness(data: []u8) void {
  _ = data;
  @compileError("TODO: Implement");
}

/// Has no runtiume cost when endianness does not match as it mutates data to change the endianness in place
/// Mutates the header too to reflect the change
pub fn initMutable(data: []u8) !GetMarkovGenFromRuntimeStats(statsWithSameEndianness(data)) {
  const stats = Stats.ModelStats.fromBytes(data);
  if (CpuEndianness != stats.endian) swapEndianness(data);

  @compileError("TODO: Implement");
  // return initImmutableUncopyable(data, allocator);
}

/// This may have runtime cost of interchanging endianness if a model with inappropriate endianness is loaded
pub fn initImmutableCopyable(data: []const u8, allocator: std.mem.Allocator) !GetMarkovGenFromRuntimeStats(statsWithSameEndianness(data)) {
  const stats = Stats.ModelStats.fromBytes(data);
  if (CpuEndianness == stats.endian) return initImmutableUncopyable(data, allocator);

  // const copy = try allocator.alloc(u8, data.len);
  // @memcpy(copy, data);
  // swapEndianness(copy);
  //
  // return initMutable(copy, allocator);
}


pub fn initImmutableUncopyable(data: []const u8, allocator: std.mem.Allocator) !GetMarkovGenFromRuntimeStats(Stats.ModelStats.fromBytes(data)) {
  _ = allocator;
  return .{};
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
    fn f(data: anytype, offset: usize) void {
      var retval = data[offset];
      comptime if (CpuEndianness != Endianness) std.mem.byteSwapAllFields(std.meta.Child(@TypeOf(data)), &retval);
      return retval;
    }
  }.f;

  return struct {
    /// table of keys
    keys: []const TableKey,
    /// table of values to the keys
    vals: []const TableVal,

    /// an array of saperate chain offsets inside of the `jt` and is again the result of `Base.flush`
    carray: []TableChain,
    /// index of the chain that is currently selected
    cindex: u32 = 0,

    // converts the input key to a `word`
    convTable: if (Key == u8) void else []u32,
    // The random number generator
    random: std.Random,

    /// Allocator for convTable and possibly carray
    allocator: std.mem.Allocator,
    /// If we have to free carray
    freeCarray: bool,

    const Self = @This();
    const TableChain = meta.TableChain(Key, Val);
    const TableKey = meta.TableKey(Key, Val);
    const TableVal = meta.TableVal(Key, Val);

    /// init this struct
    /// NOTE: we try to automatically free `carray` if it is not contained in data
    fn init(data: []const u8, carray: []u8, freeCarray: bool, allocator: std.mem.Allocator) Self {
      _ = data;
      return .{
        .keys = {},
        .vals = {},
        .carray = carray,
        .convTable = {},
        .random = {},
        .allocator = allocator,
        .freeCarray = freeCarray,
      };
    }

    /// Generate a word
    pub fn gen(self: *Self) []const u8 {
      return self.cc.convert(self.genKey()) orelse self.gen();
    }

    /// Generate a key, a key may or may not translate to a full word
    fn genKey(self: *Self) Key {
      const offset = self.carray[self.cindex].offset;
      const key0 = read(self.keys, offset);
      const key1 = read(self.keys, offset+1);
      const vals = self.vals[key0.value..key1.value];

      const context = struct {
        target: TableKey,

        fn lt(c: @This(), v: TableKey) bool {
          var vCopy = v;
          comptime if (CpuEndianness != Endianness) std.mem.byteSwapAllFields(TableKey, &vCopy);
          return c.target.value <= vCopy.value;
        }
      };

      const valIndex = std.sort.partitionPoint(TableKey, vals, context{ .target = self.random.float(Val) }, context.lt);
      const keyNext = read(vals, valIndex);

      self.carray[self.cindex].offset = key0.next + keyNext.subnext;

      return key0.key;
    }

    /// Refresh the cindex to random
    pub fn refresh(self: *Self) void {
      const context = struct {
        target: TableChain,

        fn lt(c: @This(), v: TableChain) bool {
          return c.target.offset < v.offset;
        }
      };

      self.cindex = std.sort.partitionPoint(TableChain, self.carray, context{ .target = self.random.float(Val) }, context.lt);
    }

    pub fn free(self: *Self) void {
      if (Key != u8) { self.allocator.free(self.convTable); }
      if (self.freeCarray) { self.allocator.free(self.carray); }
    }
  };
}

