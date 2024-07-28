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

pub fn random() std.Random {
  if (Prng) |_| {
    return Prng.?.random();
  } else {
    Prng = getPrng();
    return Prng.?.random();
  }
}

