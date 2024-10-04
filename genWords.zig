const std = @import("std");
const OptionalStruct = @import("common/word/meta.zig").OptionalStruct;

pub const halfusize = std.meta.Int(.unsigned, @bitSizeOf(usize)/2);

/// These are the rng function you can use for wordGenerator
/// All of these are biased (YES even linear)
/// NOTE: sqrt based implementation dont return full integer range always
pub const rngFns = struct {
  /// NOTE: using addition can overflow. Therefor, undefined behaviour is used here.
  /// this however is possibly a bad idea as behaviour of while program may be undefined.
  pub fn incrementalSum(random: std.Random, prev: halfusize, max: halfusize) halfusize {
    const randomInt = random.int(halfusize);
    const sum = init: {
      @setRuntimeSafety(false);
      break :init prev + randomInt;
    };
    return std.Random.limitRangeBiased(halfusize, sum, max);
  }

  /// Uses xor instead of sum
  pub fn incrementalXor(random: std.Random, prev: halfusize, max: halfusize) halfusize {
    return std.Random.limitRangeBiased(halfusize, prev ^ random.int(halfusize), max);
  }

  /// Simplest random number
  pub fn linear(random: std.Random, _: halfusize, max: halfusize) halfusize {
    return random.uintLessThanBiased(halfusize, max);
  }

  /// Fast square root approximation
  /// inspired from the quake implementation
  /// k=0.064450048 // minimize Integral (0 to 1) of `f(x) = abs(log2(1+x) - x - k)`
  /// err term = (1023-k) * 2^51 = 2303446080793930299
  fn fsqrt(val: u64) u32 {
    @setRuntimeSafety(false);
    @setFloatMode(std.builtin.FloatMode.optimized);
    var i: u64 = @bitCast(@as(f64, @floatFromInt(val)));
    i = (2303446080793930299 + (i >> 1)) & ~@as(u64, (1<<61));
    i = @intFromFloat(@as(f64, @bitCast(i)));
    return @truncate(i);
  }

  /// limit the fsqrt result
  fn limitedSqrt(val: u64, max: halfusize) halfusize {
    @setRuntimeSafety(false);
    return std.Random.limitRangeBiased(halfusize, @truncate(fsqrt(val)), max);
  }

  /// Sqrt based rng to generate smaller numbers more frequently
  pub fn sqrt(random: std.Random, _: halfusize, max: halfusize) halfusize {
    @setRuntimeSafety(false);
    return limitedSqrt(random.uintLessThanBiased(u64, @as(u64, max) * @as(u64, max)), max);
  }

  /// Seem more natural
  pub fn sqrtPrevMax_1(random: std.Random, prev: halfusize, max: halfusize) halfusize {
    @setRuntimeSafety(false);
    return limitedSqrt(random.uintLessThanBiased(u64, 1024 * @as(u64, (prev+1)) * @as(u64, max)), max);
  }
  pub fn sqrtPrevMax_2(random: std.Random, prev: halfusize, max: halfusize) halfusize {
    @setRuntimeSafety(false);
    return limitedSqrt(random.uintLessThanBiased(u64, @as(u64, prev + max/2) * @as(u64, max)), max);
  }

  /// repeats words sometimes
  pub fn sqrtPrev_1(random: std.Random, prev: halfusize, max: halfusize) halfusize {
    @setRuntimeSafety(false);
    return limitedSqrt(random.uintLessThanBiased(u64, @as(u64, prev + (max-prev)/2) * @as(u64, prev+1024) * 2) * 32, max);
  }
  /// Aloto x ?
  pub fn sqrtPrev_2(random: std.Random, prev: halfusize, max: halfusize) halfusize {
    @setRuntimeSafety(false);
    return limitedSqrt(random.uintLessThanBiased(u64, @as(u64, prev + (max-prev)/2) * @as(u64, prev+1024) * 64) * 4, max);
  }
};

/// The Argument to `GetWordGen` function
pub const ComptimeOptions = struct {
  /// Random word generation function
  /// This is useful because the default data is ordered by frequency of usages in english
  /// the return value __MUST__ return value less than `max`
  rngFn: fn (random: std.Random, prev: halfusize, max: halfusize) halfusize = struct {
    const functions = @typeInfo(rngFns).@"struct".decls;
    const len = functions.len;
    /// The default function, calls one of randomly selected functions every call
    fn func(random: std.Random, prev: halfusize, max: halfusize) halfusize {
      return switch(random.uintLessThanBiased(u32, len)) {
        inline 0...(len-1) => |i| @field(rngFns, functions[i].name)(random, prev, max),
        else => unreachable,
      };
    }
  }.func,

  /// If you never need to use the default wordGenerator, set this to empty string,
  /// this prevents inclusion of useless data
  defaultData: []const u8 = @embedFile("./data/words.txt"),
};

pub fn GetWordGen(comptime comptimeOptions: ComptimeOptions) type {
  return struct {
    at: halfusize = 0,
    /// index for last random word generated
    options: WordGenOptions,

    const Self = @This();

    /// Options passed to the init function
    pub const WordGenOptions = struct {
      /// RNG device used for random index generation
      random: std.Random,
      /// The data for generating words. Must be delimited by '\x00'
      data: []const u8,

      fn default() @This() {
        return .{
          .random = @import("common/word/rng.zig").random(),
          .data = comptimeOptions.defaultData,
        };
      }
    };

    /// Options are same as `WordGenOptions` except all the fields are optinonal
    pub const OptionalWordGenOptions = OptionalStruct(WordGenOptions);

    inline fn getDefault() Self {
      return .{
        .options = WordGenOptions.default(),
      };
    }

    /// Get a default initialized generator
    pub fn default() Self {
      if (comptimeOptions.defaultData.len == 0) {
        const s = @src();
        @panic(
          "function `" ++ s.fn_name ++ "` in file " ++ s.file ++ ":" ++ std.fmt.comptimePrint("{d}", .{s.line}) ++
          " Default called with zero length default data"
        );
      }

      return getDefault();
    }

    /// Initialize with given options.
    /// If the all options are null (i.e. `.{}`), it's better (faster) to use `default()` instead
    pub fn init(options: OptionalWordGenOptions) Self {
      var retval = getDefault();
      // assign all non null fields to `retval.options`
      inline for (std.meta.fields(OptionalWordGenOptions)) |f| {
        if (@field(options, f.name) != null) {
          @field(retval.options, f.name) = @field(options, f.name).?;
        }
      }
      return retval;
    }

    /// Return a random word from `self.data`.
    pub fn gen(self: *Self) []const u8 {
      self.at = comptimeOptions.rngFn(self.options.random, self.at, @truncate(self.options.data.len));
      self.at = if (std.mem.indexOfScalarPos(u8, self.options.data, self.at, '\x00')) |idx| @truncate(idx + 1) else 0;

      // Return the next word, not the one we are currently inside. This is "more" random (I think!).
      return self.next();
    }

    /// Gives the word next to current word using `self.at`.
    /// If at the end of a file gives the first word of `self.data`.
    /// NOTE: This is deterministic and thus NOT random
    pub fn next(self: *Self) []const u8 {
      const start = self.at;
      const end = std.mem.indexOfScalarPos(u8, self.options.data, self.at, '\x00') orelse self.options.data.len;
      defer self.at = if (end + 1 < self.options.data.len) @truncate(end + 1) else 0;
      return self.options.data[start..end];
    }
  };
}

test GetWordGen {
  var generator = GetWordGen(.{}).default();

  std.debug.print("TEST (GenWordGen):\n\tWORDS: ", .{});
  for (0..1024) |_|{ std.debug.print("{s} ", .{generator.gen()}); }
  std.debug.print("\n", .{});

  std.testing.refAllDecls(rngFns);
  std.testing.refAllDecls(ComptimeOptions);
  std.testing.refAllDeclsRecursive(GetWordGen(.{}));
}

