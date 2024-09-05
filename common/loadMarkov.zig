const std = @import("std");


/// Loads a model file at comptime (if all parameters are comptime known)
/// or at runtime otherwise.
fn loadFile(path: []const u8, allocator: ?std.mem.Allocator) ![]const u8 {
  if (@inComptime()) {
    if (allocator != null) @compileError("non-null allocator for comptime call to load: " ++ path);
    return ;
  }

  if (allocator == null) return error.NullAllocator;
}

test loadFile {
  const thisFile = @src().file;
  // comptime call as both `path` and `allocator` are comptime known
  const comptimeData = comptime loadFile(thisFile, null) catch unreachable;
  std.debug.print("\ncomptime Load: ```zig\n{s}```\n", .{ comptimeData });

  // Runtime call as allocator is runtime known
  const runtimeData = try loadFile(thisFile, std.testing.allocator);
  std.debug.print("\nruntime Load: ```zig\n{s}```\n", .{ runtimeData });
  std.testing.allocator.free(runtimeData);
}

const Model = struct {
  // Specifies if this is generates characters of words
  modelLen: ModelLength,

  const Self = @This();
};

pub const ModelLength = union(enum) {
  prefixLen: u8,
  postfixPostfix: u8,
};

pub fn comptimeModelLoad(comptime length: ModelLength, comptime path: []const u8, allocator: std.mem.Allocator) !Model {
  const data: []const u8 = &(@embedFile(path).*);
  comptime if (data.len < 4) @compileError("File too small to be a model");
  // `Len`(1 byte) + `KeySize`(1 byte) + `ValSize`(1 byte) + `ModelType`(1 byte) + `"\x00:MarkovModel"`()
  const stats = data[data.len - (1 + 1 + 1 + 1)..];
  const model: ModelStats = .{
    .modelLen = stats[0],
    .keyLen = stats[1],
    .valLen = stats[2],
    .modelType = std.meta.stringToEnum(ModelType, stats[3..]) orelse @compileError("Invalid File (Neither `char` nor `word`)"),
  };
}

pub fn getModel(length: ModelLength, path: []const u8, allocator: std.mem.Allocator) !Model {
  const data = blk: {
    const file = try std.fs.cwd().openFile(path, .{});
    defer file.close();
    break :blk file.readToEndAlloc(allocator, std.math.maxInt(usize));
  };

  _ = data;
}

