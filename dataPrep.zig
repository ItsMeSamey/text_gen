const std = @import("std");

const CleanUpOptions = struct {
  /// The characters that we should split at
  delim: []const u8 = " '",
  /// Characters we should skip
  skip: []const u8 = ".,;\"",
  /// The data owner (only used for free)
  allocator: std.mem.Allocator,
};

fn contains(haystack: []const u8, needle: u8) bool {
  for (haystack) |h| {
    if (h == needle) return true;
  }
  return false;
}

pub fn clean(data: []u8, option: *const CleanUpOptions) void {
  var eb: usize = 0;
  for (data.len, 0..) |character, index| {
    if (contains(option.skip, character)) {
      eb += 1;
    } else {
      data[index - eb] = if (contains(option.skip, character)) 0 else character;
    }
  }
  data.len -= eb;
}

pub fn cleanCopy(data: []const u8, option: *const CleanUpOptions, allocator: std.mem.Allocator) []u8 {
  const dest = try allocator.alloc(u8, data.len);
  @memcpy(dest, data);
  clean(dest, option);
  return try allocator.realloc(dest, dest.len);
}

