test { std.testing.refAllDeclsRecursive(@This()); }
const std = @import("std");

const RNG = @import("common/rng.zig");
const RandomIntType = RNG.RandomIntType;

/// The Argument to `GetWordGen` function
pub const ComptimeOptions = struct {
  /// Random word generation function
  /// This is useful because the default data is ordered by frequency of usages in english
  /// the return value __MUST__ return value less than `max`
  rngFn: fn(std.Random, RandomIntType, RandomIntType) RandomIntType = RNG.CompositeRngFns.randomRandomFnEverytime,

  /// If you never need to use the default wordGenerator, leave this to empty string,
  /// this is to prevent inclusion of useless data if words are loaded at runtime only
  defaultData: []const u8 = "",

  /// The saperator to use to split the words in the data file
  /// Even if you dont know the saperator, there are only 255 possibilities anyway
  saperator: u8 = '\n'
};

pub const State = struct {
  /// index for last random word generated
  at: RandomIntType = 0,
  /// RNG device used for random index generation
  random: std.Random,
};

pub fn GetOutputInterfaceType(Data: type) type {
  return struct {
    /// WARNING: Any operations on this field (without explicit knowledge of what you are doing)
    ///   are __unchecked__ illegal behaviour
    _data: GetRandomGen(.{}, Data),
    vtable: *const Vtable,

    const Vtable = struct {
      gen: *const fn (*anyopaque) []const u8,
    };

    pub fn gen(self: @This()) []const u8 { return self.vtable.gen(&self._data); }
    pub fn state(self: @This()) *State { return &self._data.state; }
    pub fn data(self: @This()) *Data { return &self._data.data.getData(); }
  };
}

/// Get a random word generator
/// `Data` must have a function `getData()` that returns a (same) slice of data everytime
pub fn GetRandomGen(comptime_options: ComptimeOptions, Data: type) type {
  return struct {
    /// this is the state of the generator
    state: State,
    /// the data that is used for generation (.data() must runturn same slice everytime)
    data: Data,

    /// Return a random word from `self.data`.
    pub fn gen(self: *@This()) []const u8 {
      const data: []const u8 = self.data.getData();
      self.state.at = comptime_options.rngFn(self.state.random, self.state.at, @truncate(data.len));
      self.state.at = if (std.mem.indexOfScalarPos(u8, data, self.state.at, comptime_options.saperator)) |idx| @truncate(idx + 1) else 0;

      // Return the next word, not the one we are currently inside. This is "more" random (I think!).
      return self.next();
    }

    /// Gives the word next to current word using `self.at`.
    /// If at the end of a file gives the first word of `self.data`.
    /// NOTE: This is deterministic and thus NOT random
    pub fn next(self: *@This()) []const u8 {
      const data: []const u8 = self.data.getData();
      const start = self.state.at;
      const end = std.mem.indexOfScalarPos(u8, data, self.state.at, comptime_options.saperator) orelse data.len;
      defer self.state.at = if (end + 1 < data.len) @truncate(end + 1) else 0;
      return data[start..end];
    }

    /// You must keep the original struct alive (and not move it)) for the returned `WordGenerator` to be valid
    /// Similar to rust's Pin<>
    pub fn any(self: @This()) GetOutputInterfaceType(Data) {
      const Self = @This();
      const Adapter = struct {
        pub fn gen(ptr: *anyopaque) []const u8 { return Self.gen(@ptrCast(@alignCast(ptr))); }
      };

      return .{
        ._data = @bitCast(self),
        .vtable = &.{
          .gen = Adapter.gen,
        },
      };
    }
  };
}

pub fn GetComptimeWordGen(comptime_options: ComptimeOptions) type {
  return GetRandomGen(comptime_options, struct{
    fn getData(_: @This()) []const u8 { return comptime_options.defaultData; }
  });
}

/// initialize the data field the struct at runtime
pub fn GetRuntimeWordGen(comptime_options: ComptimeOptions) type {
  return GetRandomGen(comptime_options, struct {
    data: []const u8,
    fn getData(self: @This()) []const u8 { return self.data; }
  });
}

fn testGenerator(comptime file_name: []const u8, comptime delimiter: []const u8) void {
  const Generator = GetComptimeWordGen(.{.defaultData = @embedFile(file_name)});
  std.debug.print("TEST ({s}):\n\tOUTPUT: ", .{file_name});
  var generator = Generator{
    .state = .{
      .random = RNG.getRandom(),
    },
    .data = .{},
  };
  for (0..16) |_|{ std.debug.print("{s}{s}", .{generator.gen(), delimiter}); }
}
test GetComptimeWordGen {
  testGenerator("./data/sentences.txt", "\n\n");
  std.debug.print("\n\n", .{});
  testGenerator("./data/words_non_alpha.txt", " ");
  std.debug.print("\n\n", .{});
  testGenerator("./data/words.txt", " ");
}

