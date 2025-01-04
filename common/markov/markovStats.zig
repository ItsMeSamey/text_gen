const std = @import("std");

pub const Range = struct {
  start: u64,
  end: u64,
};

pub const KeyEnum = enum(u2) {
  u8 = 0,
  u16 = 1,
  u24 = 2,
  u32 = 3,

  pub fn fromType(comptime K: type) KeyEnum {
    return @field(KeyEnum, @typeName(K));
  }
  pub fn Type(comptime K: KeyEnum) type {
    return std.meta.Int(.unsigned, 8 * (@as(comptime_int, @intFromEnum(K)) + 1));
  }
};

pub const ValEnum = enum(u1) {
  u16 = 0,
  u32 = 1,

  pub fn fromType(comptime V: type) ValEnum {
    return @field(ValEnum, @typeName(V));
  }
  pub fn Type(comptime K: ValEnum) type {
    return std.meta.Int(.unsigned, 16 * (@as(comptime_int, @intFromEnum(K)) + 1));
  }
};

/// Because standard's builtin has inferred type, therefor cant be in a packed struct
pub const EndianEnum = enum(u1) {
  little = 0,
  big = 1,

  pub fn fromEndian(comptime E: std.builtin.Endian) EndianEnum {
    return @field(EndianEnum, @tagName(E));
  }

  pub fn toEndian(comptime E: EndianEnum) std.builtin.Endian {
    return @field(std.builtin.Endian, @tagName(E));
  }
};

pub const ModelStats = packed struct {
  /// Actual length of markov model - 2,
  /// the only use of this is to detect loops during generation
  len_minus_2: u8,
  /// Size of the `Key` integer
  key: KeyEnum,
  /// Size of the `Val` integer
  val: ValEnum,
  /// Is this file little or big endian (hope that this variable is not affected by endianness)
  endian: EndianEnum,

  pub fn init(Len: u8, comptime keyType: type, comptime valType: type, comptime endianness: std.builtin.Endian) ModelStats {
    return .{
      .len_minus_2 = Len - 2, // min length is 2 (not 0) so we sub 2
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
  pub fn fromBytes(data: []const u8) !ModelStats {
    if (data.len < @sizeOf(ModelStats)) return error.FileTooSmall;
    var stats: ModelStats = undefined;
    @memcpy(std.mem.asBytes(&stats), data[0..@sizeOf(ModelStats)]);
    return stats;
  }
};

test {
  const stat = ModelStats.init(2, u8, u32, @import("defaults.zig").Endian);
  const statBytes = std.mem.asBytes(&stat);
  const back = try ModelStats.fromBytes(statBytes);

  try std.testing.expect(std.meta.eql(stat, back));
}

