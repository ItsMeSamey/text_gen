const std = @import("std");

const ModelType = enum(u1) {
  char,
  word,
};

pub const ModelStats = packed struct {
  /// Number of entries in the Model
  entriesLen: u64,
  /// The length of the chain
  modelLen: u8,
  /// Size of the `Key` integer
  keyLen: u8,
  /// Size of the `Val` integer
  valLen: u8,
  /// If this is a `char` or `word` model
  modelType: ModelType,
  /// Is this file little or big endian (hope that this variable is not affected by endianness)
  endian: std.builtin.Endian,
};

/// Copies the bytes (this is needed due to alignment, I think!!)
pub fn fromBytes(bytes: *const [@sizeOf(ModelStats)]u8) ModelStats {
  var stats: ModelStats = undefined;
  @memcpy(std.mem.asBytes(&stats), bytes);
  if (std.Target.Cpu.Arch.endian() != stats.endian) std.mem.byteSwapAllFields(ModelStats); 
  return stats;
}

test {
  const stat: ModelStats = .{
    .entriesLen = 0,
    .modelLen = 1,
    .keyLen = 2,
    .valLen = 3,
    .modelType = .char,
    .endian = @import("defaults.zig").Endian,
  };
  const statBytes = std.mem.asBytes(&stat);
  const back = fromBytes(statBytes);

  // std.debug.print("{any}\n{any}\n", .{statBytes, std.mem.asBytes(&back)});

  try std.testing.expect(std.meta.eql(stat, back));
}

