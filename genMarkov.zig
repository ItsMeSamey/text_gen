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
  var retval: T = @bitCast(data[offset..][0..@sizeOf(T)].*);
  if (CpuEndianness != Endianness) meta.swapEndianness(&retval);
  return retval;
}

const Offsets = struct {
  keys: Stats.Range,
  vals: Stats.Range,
  chainArray: Stats.Range,
  conversionTable: ?Stats.Range,
};

/// Get offsets of specific sections in a file
fn getOffsetsFromData(stats: Stats.ModelStats, data: []const u8) !Offsets {
  var retval: Offsets = undefined;

  var loader = struct {
    d: @TypeOf(data),
    stats: Stats.ModelStats,
    pub fn load(self: *@This()) Stats.Range {
      const r = Stats.Range{ .start = readOne(u64, self.stats.endian, self.d, self.d.len - @sizeOf(u64)), .end = self.d.len - @sizeOf(u64)};
      self.d = self.d[0..self.d.len - r.start - @sizeOf(u64)];
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

  retval.chainArray = loader.load();
  retval.vals = loader.load();
  retval.keys = loader.load();
  return retval;
}

fn swapEndianness(keys: []u8, vals: []u8, carray: []u8) void {
  _ = keys;
  _ = vals;
  _ = carray;
}

/// Has no runtiume cost when endianness does not match as it mutates data to change the endianness in place
/// Mutates the header too to reflect the change
pub fn initMutable(data: []u8, allocator: std.mem.Allocator) !GenInterface.WordGenerator {
  return getMarkovGenInterface(.mutable, data, allocator);
}

/// If endianness is not the same as native, this will copy the data, data is freed on call to free
/// This allocates slightly less memory than the size of the whole data, but in case of a word model
///   it copies a lot less (specifically does not copy the conversion table)
pub fn initImmutableCopyable(data: []const u8, allocator: std.mem.Allocator) !GenInterface.WordGenerator {
  return getMarkovGenInterface(.immutable_copyable, data, allocator);
}

/// This may have runtime cost of interchanging endianness if a model with inappropriate endianness is loaded
pub fn initImmutableUncopyable(data: []const u8, allocator: std.mem.Allocator) !GenInterface.WordGenerator {
  return getMarkovGenInterface(.immutable_uncopyable, data, allocator);
}

const InitType = enum {
  mutable,
  immutable_copyable,
  immutable_uncopyable,
};

fn getMarkovGenInterface(comptime init: InitType, data: []const u8, allocator: std.mem.Allocator) !GenInterface.WordGenerator {
  const stats = try Stats.ModelStats.fromBytes(data);
  const offsets = try getOffsetsFromData(stats, data);

  const keys = data[offsets.keys.start..offsets.keys.end];
  const vals = data[offsets.vals.start..offsets.vals.end];
  const carray = data[offsets.chainArray.start..offsets.chainArray.end];

  const convTable = if (offsets.conversionTable) |convTable| data[convTable.start..convTable.end] else null;

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

              // All of the switch cases here are (or atleast are supposed to be) comptime
              const Model = GetMarkovGen(Key, Val, if (Endianness == CpuEndianness) CpuEndianness else switch (init) {
                .mutable, .immutable_copyable => CpuEndianness,
                .immutable_uncopyable => Endianness,
              });

              const freeableSliceSize = switch (init) {
                .mutable => @sizeOf(Model),
                .immutable_copyable => if (Endianness == CpuEndianness) @sizeOf(Model) + carray.len else @sizeOf(Model) + keys.len + vals.len + carray.len,
                .immutable_uncopyable => @sizeOf(Model) + carray.len,
              };
              const freeableSlice = try allocator.alloc(u8, freeableSliceSize);

              var model: *Model = @alignCast(@ptrCast(freeableSlice[0..@sizeOf(Model)].ptr));
              if (Endianness == CpuEndianness) {
                switch (init) {
                  .mutable => {
                    try model.initFragments(keys, vals, @constCast(carray), convTable, allocator, freeableSlice);
                  },
                  .immutable_copyable, .immutable_uncopyable => {
                    @memcpy(freeableSlice[@sizeOf(Model) ..], carray);
                    try model.initFragments(keys, vals, freeableSlice[@sizeOf(Model) ..], convTable, allocator, freeableSlice);
                  },
                }
              } else {
                switch (init) {
                  .mutable => {
                    const mutableKeys = @constCast(keys);
                    const mutableVals = @constCast(vals);
                    const mutableCarray = @constCast(carray);
                    swapEndianness(mutableKeys, mutableVals, mutableCarray);
                    try model.initFragments(mutableKeys, mutableVals, mutableCarray, convTable, allocator, freeableSlice);
                  },
                  .immutable_copyable => {
                    const mutableKeys = freeableSlice[@sizeOf(Model)..][0..keys.len];
                    const mutableVals = mutableKeys.ptr[keys.len..][0..vals.len];
                    const mutableCarray = mutableVals.ptr[vals.len..][0..carray.len];
                    @memcpy(mutableKeys, keys);
                    @memcpy(mutableVals, vals);
                    @memcpy(mutableCarray, carray);
                    swapEndianness(mutableKeys, mutableVals, mutableCarray);
                    try model.initFragments(mutableKeys, mutableVals, mutableCarray, convTable, allocator, freeableSlice);
                  },
                  .immutable_uncopyable => {
                    @memcpy(freeableSlice[@sizeOf(Model) ..], carray);
                    try model.initFragments(keys, vals, freeableSlice[@sizeOf(Model) ..], convTable, allocator, freeableSlice);
                  },
                }
              }

              return GenInterface.fromGenMarkov(model);
            } 
          }
        }
      }
    }
  }
}

fn GetMarkovGen(Key: type, Val: type, Endianness: Stats.EndianEnum) type {
  const read = struct {
    fn read(comptime Output: type, data: [*]const u8, index: usize) Output {
      const optr: *const Output = @ptrCast(@alignCast(data[@sizeOf(Output) * index..][0 .. @sizeOf(Output)]));
      var oval = optr.*;
      if (CpuEndianness != Endianness) std.mem.byteSwapAllFields(Output, &oval);
      return oval;
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
      const offsetPtr: *TableChain = @ptrCast(@alignCast(self.carray[@sizeOf(TableChain) * self.cindex..]));
      const offset = offsetPtr.offset;
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

      const val = read(TableVal, self.vals, mid);
      const nextOffset = key0.next + val.subnext;
      offsetPtr.offset = @intCast(nextOffset);
      // @memcpy(self.carray[@sizeOf(TableChain) * self.cindex..][0..@sizeOf(TableChain)], std.mem.asBytes(&nextOffset));

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
    convTable: [*]const u8,
    table: [*]const u32,
    tableCount: u32,

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

      const ts = try table.toOwnedSlice();
      return .{
        .convTable = convTable.ptr,
        .table = ts.ptr,
        .tableCount = @intCast(ts.len),
      };
    }

    fn convert(self: *const @This(), input: Key) []const u8 {
      return self.convTable[self.table[input]..self.table[input + 1]-1];
    }

    fn deinit(self: *const @This(), allocator: std.mem.Allocator) void {
      allocator.free(self.table[0..self.tableCount]);
    }
  };

  return struct {
    generator: Generator,
    converter: Converter,
    /// Allocator for convTable and possibly carray
    allocator: std.mem.Allocator,
    freeableSlice: []const u8,
    
    const Self = @This();

    fn initFragments(self: *Self, keys: []const u8, vals: []const u8, carray: []u8, convTable: ?[]const u8, allocator: std.mem.Allocator, freeableSlice: []const u8) !void {
      self.* = .{
        .generator = .{
          .keys = keys.ptr,
          .vals = vals.ptr,
          .carray = carray.ptr,
          .keyCount = @intCast(keys.len / @sizeOf(TableKey)),
          .valCount = @intCast(vals.len / @sizeOf(TableVal)),
          .carrayCount = @intCast(carray.len / @sizeOf(TableChain)),
          .cindex = 0,
          .random = @import("common/rng.zig").getRandom(),
        },
        .converter = if (Key == u8) .{
          .buffer = undefined,
          .present = 0,
        } else try Converter.init(convTable.?, allocator),
        .allocator = allocator,
        .freeableSlice = freeableSlice,
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

    pub fn free(self: *Self) void {
      if (Key != u8) {
        self.converter.deinit(self.allocator);
      }
      self.allocator.free(self.freeableSlice);
    }
  };
}

