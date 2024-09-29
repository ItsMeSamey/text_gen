const std = @import("std");

const ModelType = enum(u1) {
  char,
  word,
};

pub const ModelStats = packed struct {
  /// The length of the chain
  modelLen: u8,
  /// Size of the `Key` integer
  keyLen: u8,
  /// Size of the `Val` integer
  valLen: u8,
  /// If this is a `char` or `word` model
  modelType: ModelType,
  /// Is this file little or big endian (hope that this variable is not affected by endianness)
  littleEndian: bool,

  pub fn init(chainLen: u8, keyType: type, valType: type, modelType: ModelType, endianness: std.builtin.Endian) ModelStats {
    return .{
      .modelLen = chainLen,
      .keyLen = @typeInfo(keyType).int.bits,
      .valLen = @typeInfo(valType).int.bits,
      .modelType = modelType,
      .endian = endianness,
    };
  }

  /// Copies the bytes (this is needed due to alignment, I think!)
  pub fn fromBytes(data: []const u8) ModelStats {
    comptime if (data.len < @sizeOf(ModelStats)) @compileError("File too small to be a model");
    var stats: ModelStats = undefined;
    @memcpy(std.mem.asBytes(&stats), data[0..@sizeOf(ModelStats)]);
    if (std.Target.Cpu.Arch.endian() != stats.endian) std.mem.byteSwapAllFields(ModelStats); 
    return stats;
  }
};

test {
  const stat = ModelStats.init(1, u8, u8, .char, @import("defaults.zig").Endian == .little);
  const statBytes = std.mem.asBytes(&stat);
  const back = ModelStats.fromBytes(statBytes);

  // std.debug.print("{any}\n{any}\n", .{statBytes, std.mem.asBytes(&back)});

  try std.testing.expect(std.meta.eql(stat, back));
}

