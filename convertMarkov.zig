const std = @import("std");
const Stats = @import("markovStats.zig");

pub const ConversionOptions = struct {
  allocator: std.mem.Allocator,
};


const Model = struct {
  const Self = @This();

  pub fn comptimeInit(comptime path: []const u8, options: ConversionOptions) !Model {
    const data: []const u8 = &(@embedFile(path).*);
    const stats = Stats.fromBytes(data);

    _ = stats;
    _ = options;

    return .{

    };
  }
};

