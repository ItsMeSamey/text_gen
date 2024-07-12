random: std.Random,

data: []const u8 = DEFAULTFILE,
length: u32 = DEFAULTFILE.len,
delimiter: u8 = '\x00',

const std = @import("std");
const Self = @This();
const DEFAULTFILE = @embedFile("./data/words.txt");

/// Genetates a random word and returns it.
pub fn gen(self: *const Self) []const u8 {
  // Return the next word, not the one we are currently inside. This is "more" random (I think!).
  if (std.mem.indexOfScalarPos(u8, self.data, self.random.intRangeAtMost(u32, 0, self.length), self.delimiter)) |from| {
    if (std.mem.indexOfScalarPos(u8, self.data, from+1, self.delimiter)) |till| {
      return self.data[from..till]; // everything normal here
    } else {
      return self.data[from..]; // we were in last second word
    }
  } else if (std.mem.indexOfScalar(u8, self.data, self.delimiter)) |till| {
    return self.data[0..till]; // we were in the last word
  } else {
    return self.data; // just one word in a file?
  }
}

test Self {
  const print = std.debug.print;
  print("TEST Self:\n\tgen: ", .{});
  const generator: Self = .{ .random = @import("rng.zig").random() };

  // print 4 random words, using .gen()
  for (0..4) |_|{ print("{s} ", .{generator.gen()}); }
  print("\n\tgenN: ", .{});
}

