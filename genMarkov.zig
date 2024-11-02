const std = @import("std");
const Stats = @import("common/markov/markovStats.zig");

const CpuEndianness = Stats.EndianEnum.fromEndian(@import("builtin").cpu.arch.endian());

fn statsWithSameEndianness(data: []const u8) Stats {
  var stats = Stats.ModelStats.fromBytes(data);
  stats.endian = CpuEndianness;
  return stats;
}

/// Has no runtiume cost when endianness does not match as it mutates data to change the endianness in place
/// Mutates the header too to reflect the change
pub fn initMutable(data: []u8, allocator: std.mem.Allocator) GetMarkovGenFromRuntimeStats(statsWithSameEndianness(data)) {
  const stats = Stats.ModelStats.fromBytes(data);
  if (CpuEndianness == stats.endian) return initImmutableUncopyable(data, allocator);

  @compileError("TODO: Implement");
  // Byte swap all fields
}

/// This may have runtime cost of interchanging endianness if a model with inappropriate endianness is loaded
pub fn initImmutableCopyable(data: []const u8, allocator: std.mem.Allocator) GetMarkovGenFromRuntimeStats(statsWithSameEndianness(data)) {
  const stats = Stats.ModelStats.fromBytes(data);
  if (CpuEndianness == stats.endian) return initImmutableUncopyable(data, allocator);

  @compileError("TODO: Implement");
  // var copy = allocator.alloc(u8, data.len);
  // @memcpy(copy, data);
  // Byte swap all fields of copy
}

pub fn initImmutableUncopyable(data: []const u8, allocator: std.mem.Allocator) GetMarkovGenFromRuntimeStats(Stats.ModelStats.fromBytes(data)) {
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

fn GetMarkovGen(comptime Key: type, comptime Val: type, comptime Endianness: Stats.EndianEnum) type {
  return struct {
    /// an array of saperate chain offsets inside of the `jt` and is again the result of `Base.flush`
    carray: []u32,
    /// index of the chain that is currently selected
    cindex: u32 = 0,

    /// a kind of jump table that is result of `Base.flush`
    jt: []const u8,
    /// length of the markov chain
    len: u8,

    const Self = @This();

    pub fn gen(self: *Self) Key {
      return "";
    }

    pub fn refresh(self: *Self) void {
      @compileError("TODO: Implement");
      // In case we have multiple disconnected chains in the generated model
      // This function should reandomly select one with the probability proportional to the number of nodes in that chain
    }
  };
}

