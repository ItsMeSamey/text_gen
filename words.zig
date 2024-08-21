const std = @import("std");

/// RNG device used for random index generation
random: std.Random,
/// How does your file split words
delimiter: u8 = '\x00',
/// The file used for generating words.
data: []const u8 = @embedFile("./data/words.txt"),
/// index for last random word generated
at: usize = 0,

const Self = @This();

/// Return a random word from `self.data`.
pub fn gen(self: *Self) []const u8 {
  self.at = @mod(self.at ^ self.random.int(usize), self.data.len);
  self.at = if (std.mem.indexOfScalarPos(u8, self.data, self.at, self.delimiter)) |idx| idx + 1 else 0;

  // Return the next word, not the one we are currently inside. This is "more" random (I think!).
  return self.next();
}

/// Gives the word next to current word using `self.at`.
/// If at the end of a file gives the first word of `self.data`.
/// NOTE: This is deterministic and thus NOT random
pub fn next(self: *Self) []const u8 {
  const start = self.at;
  const end = std.mem.indexOfScalarPos(u8, self.data, self.at, self.delimiter) orelse self.data.len;
  defer self.at = if (end + 1 < self.data.len) end + 1 else 0;
  return self.data[start..end];
}

test Self {
  const print = std.debug.print;
  var generator: Self = .{ .random = @import("common/rng.zig").random() };

  // print 4 random words, using .gen()
  print("TEST Self:\n\tgen: ", .{});
  for (0..4) |_|{ print("{s} ", .{generator.gen()}); }
  print("\n ", .{});
}

