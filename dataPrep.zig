const std = @import("std");

const CleanUpOptions = struct {
  /// This is what all the delimiters are replced by
  repl: u8 = '\x00',
  /// The characters that will be replaced by repl
  delim: []const u8 = " -.!?,;\n\t\r",
  /// Characters we should skip, next characters are pushed back to their empty space
  skip: []const u8 = "\"'()[]{}",
  /// If true, converts all the characters to lower case
  normalize: bool = true,
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
/// Note: this function mutates the `data_`
pub fn clean(data_: []u8, comptime option: CleanUpOptions) []u8 {
  var data = data_;

  var idx: usize = 0;
  var iter = std.mem.tokenizeAny(u8, data, option.delim);
  while (iter.next()) |token| {
    for (token) |c| {
      if (!contains(option.skip, c)) {
        data[idx] = if (option.normalize) std.ascii.toLower(c) else c;
        idx += 1;
      }
    }
    data[idx] = option.repl;
    idx += 1;
  }

  data.len = idx;
  return data;
}

/// Create a clean copy of data
/// Cleaning removes any `\x00` values
pub fn cleanCopy(data: []const u8, option: *const CleanUpOptions, allocator: std.mem.Allocator) []u8 {
  const dest = try allocator.dupe(u8, data);
  return try allocator.realloc(dest, clean(dest, option).len);
}

