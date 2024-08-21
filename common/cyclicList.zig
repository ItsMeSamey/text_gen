const std = @import("std");

/// Make a cyclic list with a list of given type T
/// Use `len` = `0` if you want to have slice buffer you can assign at runtime 
pub fn GenCyclicList(Len: comptime_int, T: type) type {
  return GenPaddedCyclicList(Len, Len * 4, T);
}

pub fn GenPaddedCyclicList(Len: comptime_int, BufLen: comptime_int, T: type) type {
  comptime {
    std.debug.assert(Len > 0);
    std.debug.assert(BufLen >=  Len);
  }

  return struct {
    /// The buffer used for cyclic list
    buf: [BufLen]T = undefined,
    /// end of the buffer
    end: usize = 0,

    const Self = @This();

    fn emplace(self: *Self) void {
      if (self.end < Len) return;

      if (BufLen >= Len * 2 or BufLen - Len >= Len - self.end) {
        std.mem.copyBackwards(T, self.buf[Len-self.end..Len], self.buf[0..self.end]);
        @memcpy(self.buf[0..Len-self.end], self.buf[BufLen-(Len-self.end)..BufLen]);
      } else {
        std.mem.rotate(T, self.buf, self.buf.len - (1 + self.end));
      }
      self.end = self.buf.len - 1;
    }

    pub fn getSlice(self: *Self) [Len]T {
      self.emplace();
      return self.buf;
    }

    pub fn push(self: *Self, val: T) void {
      self.buf[self.at] = val;
      self.end = if (self.end + 1 == self.buf.len) 0 else self.end + 1;
    }
  };
}

