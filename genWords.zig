//! The random word generator

const std = @import("std");
const OptionalStruct = @import("common/word/meta.zig").OptionalStruct;

/// index for last random word generated
at: usize = 0,
options: Options,

const Self = @This();

pub const Options = struct {
  /// RNG device used for random index generation
  random: std.Random,
  /// The data for generating words. Must be delimited by '\x00'
  data: []const u8 = @embedFile("./data/words.txt"),

  rngFn: *const fn (random: std.Random, prevPos: usize, len: usize) usize = struct{
    fn func(random: std.Random, prevPos: usize, _: usize) usize {
      return prevPos ^ random.int(usize);
    }
  }.func,
  deinitFn: *const fn () void = struct {
    fn func() void {}
  }.func,

  fn default() Options {
    return .{
      .random = @import("common/word/rng.zig").random(),
    };
  }
};

pub const OptionalOptions = OptionalStruct(Options);

// Options are same as `Options` struct excerpt all the fields are optinonal
// to make a gefault generator, call with empty tuple i.e. `init(.{})`
fn init(options: OptionalOptions) Self {
  var retval = Self{ .options = Options.default() };

  // assign all non null fields to `retval.options`
  inline for (std.meta.fields(OptionalOptions)) |f| {
    if (@field(options, f.name) != null) {
      @field(retval.options, f.name) = @field(options, f.name).?;
    }
  }

  return retval;
}

/// Return a random word from `self.data`.
pub fn gen(self: *Self) []const u8 {
  self.at = @mod(self.options.rngFn(self.options.random, self.at, self.options.data.len), self.options.data.len);
  self.at = if (std.mem.indexOfScalarPos(u8, self.options.data, self.at, '\x00')) |idx| idx + 1 else 0;

  // Return the next word, not the one we are currently inside. This is "more" random (I think!).
  return self.next();
}

/// Gives the word next to current word using `self.at`.
/// If at the end of a file gives the first word of `self.data`.
/// NOTE: This is deterministic and thus NOT random
pub fn next(self: *Self) []const u8 {
  const start = self.at;
  const end = std.mem.indexOfScalarPos(u8, self.options.data, self.at, '\x00') orelse self.options.data.len;
  defer self.at = if (end + 1 < self.options.data.len) end + 1 else 0;
  return self.options.data[start..end];
}

test Self {
  const print = std.debug.print;
  var generator = Self.init(.{});

  // print 4 random words, using .gen()
  print("TEST Self:\n\tgen: ", .{});
  for (0..4) |_|{ print("{s} ", .{generator.gen()}); }
  print("\n ", .{});
}

