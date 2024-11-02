const std = @import("std");


pub const KeyEnum = enum(u2) {
  u8 = 0,
  u16 = 1,
  u32 = 2,
  u64 = 3,

  pub fn fromType(comptime K: type) KeyEnum {
    return std.meta.stringToEnum(KeyEnum, @typeName(K)) orelse {
      @compileError("Type is not a valid KeyEnum Entry");
    };
  }

  pub fn Type(comptime K: KeyEnum) type {
    return std.meta.Int(.unsigned, 8 * (1 << @intFromEnum(K)));
  }
};
pub const ValEnum = enum(u1) {
  f32 = 0,
  f64 = 1,

  pub fn fromType(comptime V: type) ValEnum {
    return std.meta.stringToEnum(ValEnum, @typeName(V)) orelse {
      @compileError("Type is not a valid ValEnum Entry");
    };
  }

  pub fn Type(comptime K: ValEnum) type {
    return std.meta.Float(32 * (1 << @intFromEnum(K)));
  }
};
/// Because standard's builtin has inferred type
pub const EndianEnum = enum(u1) {
  little = 0,
  big = 1,

  pub fn fromEndian(comptime E: std.builtin.Endian) KeyEnum {
    return std.meta.stringToEnum(EndianEnum, @tagName(E)) orelse {
      @compileError("Invalid Endianness");
    };
  }

  pub fn toEndian(comptime E: std.builtin.Endian) KeyEnum {
    return std.meta.stringToEnum(EndianEnum, @tagName(E)) orelse {
      @compileError("Invalid Endianness");
    };
  }
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
      .key = KeyEnum.fromType(keyType),
      // Val must be one of these types
      .val = ValEnum.fromType(valType),
      .endian = EndianEnum.fromEndian(endianness),
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

