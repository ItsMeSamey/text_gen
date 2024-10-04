const std = @import("std");

const ModelType = enum {
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
  wordModel: bool,
  /// Is this file little or big endian (hope that this variable is not affected by endianness)
  littleEndian: bool,

  pub fn init(chainLen: u8, keyType: type, valType: type, modelType: ModelType, endianness: std.builtin.Endian) ModelStats {
    return .{
      .modelLen = chainLen,
      .keyLen = @typeInfo(keyType).int.bits,
      .valLen = @typeInfo(valType).int.bits,
      .wordModel = modelType == .word,
      .littleEndian = endianness == .little,
    };
  }

  pub fn flush(self: ModelStats,writer: std.io.AnyWriter, ) !void {
    return writer.writeStructEndian(self, if (self.littleEndian) .little else .big);
  }

  /// Copies the bytes (this is needed due to alignment, I think!)
  pub fn fromBytes(data: []const u8) ModelStats {
    if (data.len < @sizeOf(ModelStats)) return error.FileTooSmall;
    var stats: ModelStats = undefined;
    @memcpy(std.mem.asBytes(&stats), data[0..@sizeOf(ModelStats)]);

    // NOTE: This is currently not needed as all fields are one byte
    // if ((@import("builtin").target.cpu.arch.endian() == .little) != stats.littleEndian) std.mem.byteSwapAllFields(ModelStats); 

    return stats;
  }
};

test {
  const stat = ModelStats.init(1, u8, u8, .char, @import("defaults.zig").Endian);
  const statBytes = std.mem.asBytes(&stat);
  const back = try ModelStats.fromBytes(statBytes);

  // std.debug.print("{any}\n{any}\n", .{statBytes, std.mem.asBytes(&back)});

  try std.testing.expect(std.meta.eql(stat, back));
}

