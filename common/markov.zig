const std = @import("std");
const DataArrayList = std.ArrayList(struct { data: []const u8, allocator: std.mem.Allocator, });

pub fn GenBase(Len: comptime_int, Key: type) type {
  comptime std.debug.assert(Len > 1);

  const meta = @import("meta.zig");
  const MetaKeyType = switch (Key) {
    u8, u32 => [Len]Key,
    // Unexpected type
    else => @compileError("Key must be type `u8` or `u32` but `" ++ @typeName(Key) ++ "` was provided"),
  };

  // Make a int type that can store the whole chain in case of u8 or
  // a u32 is an index to the given word in some array
  const KeyType = meta.Uint(Len, MetaKeyType);
  const ValType = u32;
  const MarkovMap = std.AutoHashMap(KeyType, ValType);

  return struct {
    /// The array to store allocated data that will be freed by deinit.
    data: DataArrayList,
    /// Count of The markove chain 
    map: MarkovMap,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator) Self {
      return .{
        .data = DataArrayList.init(allocator),
        .map = MarkovMap.init(allocator),
      };
    }

    /// Store the allocator and reference to data that we will free on deinit call
    pub fn storeFreeable(self: *Self, data: []const u8, owner: std.mem.Allocator) !void {
      self.data.append(.{ .data = data, .allocator = owner }) catch |e| {
        std.debug.print("Error occurred: {}", .{e});
        return error.FreeableDataAddError;
      };
    }

    /// Increment the value for encountered key
    pub fn increment(self: *Self, key: MetaKeyType) !void {
      var dest = try self.map.allocator.create(KeyType);
      @memcpy(&dest, key);
      const result = try self.map.getOrPut(dest);
      result.value_ptr.* = if (result.found_existing) result.value_ptr.* + 1 else 0;
    }

    /// Free everything owned by this (Base) object
    pub fn deinit(self: *Self) void {
      var iterator = self.map.iterator();
      while (iterator.next()) |key| { self.map.allocator.free(key.key_ptr); }
      for (self.data.items) |item| { item.allocator.free(item.data); }

      self.data.deinit();
      self.map.deinit();
    }
  };
}

