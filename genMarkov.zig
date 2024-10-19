const std = @import("std");
const Loader = @import("common/loadMarkov.zig");

const Self = @This();

pub fn init(modelPath: []const u8, allocator: ?std.mem.Allocator) Self {
  const data = Loader.loadFile(modelPath, allocator);
  _ = data;
}

