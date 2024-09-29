const std = @import("std");

const Stats = @import("markovStats.zig");

const Model = struct {
  // Specifies if this is generates characters of words
  modelLen: ModelLength,

  const Self = @This();
};

pub const ModelLength = union(enum) {
  prefixLen: u8,
  postfixPostfix: u8,
};


pub fn comptimeModelLoad(comptime path: []const u8, allocator: std.mem.Allocator) !Model {
  const data: []const u8 = &(@embedFile(path).*);
  const model = Stats.fromBytes(data);

  const Key = std.meta.Int(.unsigned, model.keyLen);
  const Val = std.meta.Int(.unsigned, model.valLen);
  const Len = model.modelLen;
  _ = Key;
  _ = Val;
  _ = Len;

  _ = allocator;
}

pub fn getModel(path: []const u8, allocator: std.mem.Allocator) !Model {
  const data = blk: {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    break :blk file.readToEndAlloc(allocator, std.math.maxInt(usize));
  };

  const model = Stats.fromBytes(data);

  _ = model;
}

