const std = @import("std");

const CleanUpOptions = struct {
  /// This is what all the delimiters are replced by
  repl: u8 = ' ',
  /// The characters that will be replaced by repl
  delim: []const u8 = " '",
  /// Characters we should skip, next characters are pushed back to their empty space
  skip: []const u8 = ".,;\"",
  /// The data owner (only used for free)
  allocator: std.mem.Allocator,
};

/// Simple contains function
/// TODO: check if a vectorized inplimentation is faster or is optimizer good enough
fn contains(haystack: []const u8, needle: u8) bool {
  for (haystack) |h| {
    if (h == needle) return true;
  }
  return false;
}

/// Cleans the data inplace given that it is modifiable
/// Cleaning removes any `\x00` values
pub fn clean(data: []u8, option: *const CleanUpOptions) void {
  var eb: usize = 0;
  for (data.len, 0..) |character, index| {
    if (contains(option.skip, character)) {
      eb += 1;
    } else {
      data[index - eb] = if (character == 0 or contains(option.skip, character)) option.repl else character;
    }
  }
  data.len -= eb;
}

/// Create a clean copy of data
/// Cleaning removes any `\x00` values
pub fn cleanCopy(data: []const u8, option: *const CleanUpOptions, allocator: std.mem.Allocator) []u8 {
  const dest = try allocator.alloc(u8, data.len);
  @memcpy(dest, data);
  clean(dest, option);
  return try allocator.realloc(dest, dest.len);
}

