test { std.testing.refAllDeclsRecursive(@This()); }
const std = @import("std");
const OptionalStruct = @import("common/word/meta.zig").OptionalStruct;

const RNG = @import("common/rng.zig");

const RandomIntType = RNG.RandomIntType;

/// The Argument to `GetWordGen` function
pub const ComptimeOptions = struct {
  /// Random word generation function
  /// This is useful because the default data is ordered by frequency of usages in english
  /// the return value __MUST__ return value less than `max`
  rngFn: fn(std.Random, RandomIntType, RandomIntType) RandomIntType = RNG.CompositeRngFns.randomRandomFnEverytime,

  /// If you never need to use the default wordGenerator, set this to empty string,
  /// this prevents inclusion of useless data
  defaultData: []const u8 = @embedFile("./data/words.txt"),
};

pub fn GetWordGen(comptime comptimeOptions: ComptimeOptions) type {
  return struct {
    at: RandomIntType = 0,
    /// index for last random word generated
    options: Options,

    /// Options passed to the init function
    pub const Options = struct {
      /// RNG device used for random index generation
      random: std.Random,
      /// The data for generating words. Must be delimited by '\x00'
      data: []const u8,

      fn default() @This() {
        return .{
          .random = RNG.getRandom(),
          .data = comptimeOptions.defaultData,
        };
      }
    };

    /// Options are same as `WordGenOptions` except all the fields are optinonal
    pub const OptionalOptions = OptionalStruct(Options);

    /// Initialize with given options.
    /// If the all options are null (i.e. `.{}`), it's better (faster) to use `default()` instead
    pub fn init(options: OptionalOptions) @This() {
      if (comptimeOptions.defaultData.len == 0 and options.data == null) {
        const s = @src();
        @panic(
          "function `" ++ s.fn_name ++ "` in file " ++ s.file ++ ":" ++ std.fmt.comptimePrint("{d}", .{s.line}) ++
          " Default called with zero length default data"
        );
      }

      var retval = @This() {
        .options = Options.default(),
      };

      // assign all non null fields to `retval.options`
      inline for (std.meta.fields(OptionalOptions)) |f| {
        if (@field(options, f.name) != null) {
          @field(retval.options, f.name) = @field(options, f.name).?;
        }
      }
      return retval;
    }

    /// Return a random word from `self.data`.
    pub fn gen(self: *@This()) []const u8 {
      self.at = comptimeOptions.rngFn(self.options.random, self.at, @truncate(self.options.data.len));
      self.at = if (std.mem.indexOfScalarPos(u8, self.options.data, self.at, '\x00')) |idx| @truncate(idx + 1) else 0;

      // Return the next word, not the one we are currently inside. This is "more" random (I think!).
      return self.next();
    }

    /// Gives the word next to current word using `self.at`.
    /// If at the end of a file gives the first word of `self.data`.
    /// NOTE: This is deterministic and thus NOT random
    pub fn next(self: *@This()) []const u8 {
      const start = self.at;
      const end = std.mem.indexOfScalarPos(u8, self.options.data, self.at, '\x00') orelse self.options.data.len;
      defer self.at = if (end + 1 < self.options.data.len) @truncate(end + 1) else 0;
      return self.options.data[start..end];
    }

    const GenInterface = @import("genInterface.zig");
    /// You must keep the original struct alive (and not move it)) for the returned `WordGenerator` to be valid
    /// Similar to rust's Pin<>
    pub fn any(self: *@This()) GenInterface.WordGenerator {
      return GenInterface.autoConvert(self);
    }
  };
}

test GetWordGen {
  std.testing.refAllDeclsRecursive(GetWordGen(.{}));
  std.testing.refAllDeclsRecursive(ComptimeOptions);
  
  var generator = GetWordGen(.{}).init(.{});

  std.debug.print("TEST (GenWordGen):\n\tWORDS: ", .{});
  for (0..1024) |_|{ std.debug.print("{s} ", .{generator.gen()}); }
  std.debug.print("\n", .{});
}

