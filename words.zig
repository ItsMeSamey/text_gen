const std = @import("std");

const DEFAULTFILE = @embedFile("./data/words.txt");

/// The text generation interface that uses random words
const TextGen = struct {
  random: std.Random,

  data: []const u8 = DEFAULTFILE,
  length: u32 = DEFAULTFILE.len,
  delimiter: u8 = '\x00',
  replace: u8 = ' ',

  const Self = @This();

  /// Genetates a random word and returns it.
  fn gen(self: *const Self) []const u8 {
    // Return the next word, not the one we are currently inside. This is "more" random (I think!).
    if (std.mem.indexOfScalarPos(u8, self.data, self.Random.intRangeAtMost(u32, 0, self.Length), self.delimiter)) |from| {
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

  /// generate `count` random words. length of mem >= count or undefined behaviour.
  fn genN(self: *const Self, out: [][] const u8) void {
    for (0..out.len) |i| { out[i] = self.gen(); }
  }
};


test TextGen {
  const print = std.debug.print;
  print("TEST TextGen:\n\tgen: ", .{});
  // RNG object to be used
  var Prng = std.rand.DefaultPrng.init(init: {
    var seed: u64 = undefined;
    try std.posix.getrandom(std.mem.asBytes(&seed));
    seed ^= @abs(std.time.milliTimestamp());
    break :init seed;
  });
  // TextGen initialized
  const generator: TextGen = .{ .random = Prng.random(), };

  // print 4 random words, using .gen()
  for (0..4) |_|{ print("{s} ", .{generator.gen()}); }
  print("\n\tgenN: ", .{});

  // print 6 random words using .genN()
  var arr: [6][*:0]const u8 = undefined;
  generator.genN(&arr);
  for (arr) |x|{ print("{s} ", .{x}); }
  print("\n", .{});
}

