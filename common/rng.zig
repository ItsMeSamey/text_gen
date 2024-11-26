test { std.testing.refAllDeclsRecursive(@This()); }
const std = @import("std");

fn getPrng() std.Random.DefaultPrng {
  if (@inComptime()) @compileError("Rng cannot be initilaized at comptime");
  return std.Random.DefaultPrng.init(init: {
    const bigTimestamp = std.time.nanoTimestamp();
    const allegedTimestamp: i64 = @truncate(bigTimestamp ^ (bigTimestamp >> 64));
    var timestamp: u64 = @bitCast(allegedTimestamp);
    var seed: u64 = undefined;

    std.posix.getrandom(std.mem.asBytes(&seed)) catch |e| {
      std.log.err("Recoverable Error: RNG initialization failed:\n{}", .{e});
      timestamp ^= @bitCast(std.time.microTimestamp());
    };
    break :init timestamp ^ seed;
  });
}

/// RNG object to be used
var Prng: ?std.Random.DefaultPrng = null;

pub fn getRandom() std.Random {
  if (Prng) |_| {
    return Prng.?.random();
  } else {
    Prng = getPrng();
    return Prng.?.random();
  }
}

pub const halfusize = std.meta.Int(.unsigned, @bitSizeOf(usize)/2);

/// These are the rng function you can use for wordGenerator
/// All of these are biased (YES even linear)
/// NOTE: sqrt based implementation dont return full integer range always
pub const RngFns = struct {
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

pub const CompositeRngFns = struct {
  // Randomly choose one on the random functions
  pub fn randomRandomFn(random: std.Random) (*const fn(random: std.Random, prev: halfusize, max: halfusize) halfusize) {
    const functions = @typeInfo(RngFns).@"struct".decls;
    const len = functions.len;

    return switch(random.uintLessThanBiased(u32, len)) {
      inline 0...(len-1) => |i| @field(RngFns, functions[i].name),
      else => unreachable,
    };
  }

  /// The default function, calls one of randomly selected functions every call
  pub fn randomRandomFnEverytime(random: std.Random, prev: halfusize, max: halfusize) halfusize {
    return CompositeRngFns.randomRandomFn(random)(random, prev, max);
  }
};

