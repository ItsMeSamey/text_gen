const std = @import("std");

const strEq = @import("common/stringComparer.zig").strEq;
const strHash = std.hash_map.hashString;

fn CharMakov(Len: comptime_int) type {
  const Base = @import("common/trainMarkov.zig").GenBase(Len, u8);

  return struct {
    /// The base containing the modal
    base: Base,

    const Self = @This();

    /// Create the instance of `@This()` object
    pub fn init(allocator: std.mem.Allocator) type {
      return .{ .base = Base.init(allocator) };
    }

    /// You can call this multiple times to train with multiple files.
    /// WARNING: Data must Not be deleted/free'd during for the lifetime of `self`
    /// `owner` must be null if data is not allocated, or you want to keep ownership of the data.
    /// `owner` is used to free memory when deinit is called.
    pub fn train(self: *Self, data: []const u8, owner: ?std.mem.Allocator) !void {
      if (data.len < Len) return error.InsufficientData;
      if (owner != null) { try self.base.storeFreeable(data, owner.?); }
      for (0..data.len-(Len-1)) |i| {
        try self.base.increment(data[i..i+Len]);
      }
    }

    /// Writes the data to `writer` does *NOT* deinitialize anything
    pub fn flush(self: *Self, writer: std.io.AnyWriter) void {
      self.base.flush(writer, std.math.maxInt(u8));
      try writer.writeAll("char");
    }

    pub fn deinit(self: *Self) void {
      self.base.deinit();
    }
  };
}

const stable = CharMakov(4);

test {
  const s: stable = undefined;
  _ = s;
}

