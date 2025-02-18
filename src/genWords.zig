test { std.testing.refAllDeclsRecursive(@This()); }
const std = @import("std");
const OptionalStruct = @import("common/meta.zig").OptionalStruct;

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

  /// The saperator to use to split the words in the data file
  saperator: u8 = '\n'
};

pub fn GetRandomGen(comptimeOptions: ComptimeOptions, State: type, Interface: type) type {
  return struct {
    at: RandomIntType = 0,
    /// index for last random word generated
    options: Options,
    /// this is the state of the generator
    state: State = .{},

    /// Options passed to the init function
    pub const Options = struct {
      /// RNG device used for random index generation
      random: std.Random,
      /// The data for generating words. Must be delimited by 'comptimeOptions.saperator'
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
    pub fn init(optional_options: ?OptionalOptions) @This() {
      if (comptimeOptions.defaultData.len == 0 and (optional_options == null or optional_options.?.data == null or optional_options.?.data.?.len == 0)) {
        // Data was not specified at both runtime and comptime, this does not make any sense
        const err_str = "data was not specified at both comptime and runtime";
        if (@inComptime()) @compileError(err_str);
        const s = @src(); // Fallback info for if stack traces are disabled
        @panic(std.fmt.comptimePrint("function `{s}` in file `{s}:{d}`\n{s}", .{s.fn_name, s.file, s.line, err_str}));
      }

      var retval = @This() {
        .options = Options.default(),
      };

      // assign all non null fields to `retval.options`
      if (optional_options) |options| {
        inline for (std.meta.fields(OptionalOptions)) |f| {
          if (@field(options, f.name) != null) {
            @field(retval.options, f.name) = @field(options, f.name).?;
          }
        }
      }
      return retval;
    }

    /// Return a random word from `self.data`.
    pub fn gen(self: *@This()) []const u8 {
      self.at = comptimeOptions.rngFn(self.options.random, self.at, @truncate(self.options.data.len));
      self.at = if (std.mem.indexOfScalarPos(u8, self.options.data, self.at, comptimeOptions.saperator)) |idx| @truncate(idx + 1) else 0;

      // Return the next word, not the one we are currently inside. This is "more" random (I think!).
      return self.next();
    }

    /// Gives the word next to current word using `self.at`.
    /// If at the end of a file gives the first word of `self.data`.
    /// NOTE: This is deterministic and thus NOT random
    pub fn next(self: *@This()) []const u8 {
      const start = self.at;
      const end = std.mem.indexOfScalarPos(u8, self.options.data, self.at, comptimeOptions.saperator) orelse self.options.data.len;
      defer self.at = if (end + 1 < self.options.data.len) @truncate(end + 1) else 0;
      return self.options.data[start..end];
    }

    /// You must keep the original struct alive (and not move it)) for the returned `WordGenerator` to be valid
    /// Similar to rust's Pin<>
    pub fn any(self: *@This()) Interface {
      const Adapter = struct {
        pub fn _gen(ptr: *anyopaque) []const u8 { return gen(@ptrCast(@alignCast(ptr))); }
      };

      return Interface{.ptr = @ptrCast(self), ._gen = Adapter._gen};
    }
  };
}

pub const AnyWordGen = struct {
  ptr: *anyopaque,
  _gen: *const fn (*anyopaque) []const u8,

  pub fn gen(self: @This()) []const u8 { return self._gen(self.ptr); }
};

pub fn GetWordGen(comptimeOptions: ComptimeOptions) type {
  return GetRandomGen(comptimeOptions, struct{}, AnyWordGen);
}


fn testGenerator(comptime file_name: []const u8, comptime delimiter: []const u8) void {
  const Generator = GetWordGen(.{.defaultData = @embedFile(file_name)});
  std.debug.print("TEST ({s}):\n\tOUTPUT: ", .{file_name});
  var generator = Generator.init(.{});
  for (0..16) |_|{ std.debug.print("{s}{s}", .{generator.gen(), delimiter}); }
}
test GetWordGen {
  testGenerator("./data/sentences.txt", "\n\n");
  std.debug.print("\n\n", .{});
  testGenerator("./data/words_non_alpha.txt", " ");
  std.debug.print("\n\n", .{});
  testGenerator("./data/words.txt", " ");
}

