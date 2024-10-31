const std = @import("std");


pub const KeyEnum =  enum(u2) {
  u8 = 0,
  u16 = 1,
  u32 = 3,
  u64 = 4,
};
pub const ValEnum =  enum(u1) {
  f32 = 0,
  f64 = 1,
};
pub const EndianEnum = enum(u1) {
  little = 0,
  big = 1,
};

pub const ModelStats = packed struct {
  /// The length of the chain
  modelLen: u4,
  /// Size of the `Key` integer
  key: KeyEnum,
  /// Size of the `Val` integer
  val: ValEnum,
  /// Is this file little or big endian (hope that this variable is not affected by endianness)
  endian: EndianEnum,

  pub fn init(chainLen: u8, keyType: type, valType: type, endianness: std.builtin.Endian) ModelStats {
    comptime {
      std.debug.assert(chainLen >= 2);
    }
    return .{
      // We assume chain length to be >= 2
      .modelLen = @intCast(chainLen - 2),
      // Key must be one of these types
      .key = std.meta.stringToEnum(KeyEnum, @typeName(keyType)).?,
      // Val must be one of these types
      .val = std.meta.stringToEnum(ValEnum, @typeName(valType)).?,
      .endian = std.meta.stringToEnum(EndianEnum, @tagName(endianness)).?,
    };
  }

  pub fn flush(self: ModelStats, writer: std.io.AnyWriter) !void {
    return writer.writeStruct(self);
    // NOTE: This is currently not needed as all fields are one byte
    // return writer.writeStructEndian(self, if (self.littleEndian) .little else .big);
  }

  /// Copies the bytes (this is needed due to alignment, I think!)
  pub fn fromBytes(data: []const u8) ModelStats {
    if (data.len < @sizeOf(ModelStats)) return error.FileTooSmall;
    var stats: ModelStats = undefined;
    @memcpy(std.mem.asBytes(&stats), data[0..@sizeOf(ModelStats)]);
    return stats;
  }
};

test {
  const stat = ModelStats.init(2, u8, u8, .char, @import("defaults.zig").Endian);
  const statBytes = std.mem.asBytes(&stat);
  const back = try ModelStats.fromBytes(statBytes);

  try std.testing.expect(std.meta.eql(stat, back));
}

