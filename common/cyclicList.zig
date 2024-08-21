const std = @import("std");

/// Make a cyclic list with a list of given type T
/// Len is maximum len of a cycle,
/// You may want to call `GenPaddedCyclicList` with a larger multiplier of `Len`
/// to get better performance (depending on your usage).
pub fn GenCyclicList(Len: comptime_int, T: type) type {
  // 16 here is arbitrarily chosen
  return GenPaddedCyclicList(Len, Len * 16, T);
}

/// Make a cyclic list with a list of given type T
/// Len is maximum len of a cycle,
/// BufLen is the length of buffer
pub fn GenPaddedCyclicList(Len: comptime_int, BufLen: comptime_int, T: type) type {
  comptime {
    if (Len <= 0) @compileError("Cannot have a zero-sized cyclic list");
    if (BufLen <  Len) @compileError("Buffer length cannot be smaller than Capacity of cyclic list");
  }

  return struct {
    /// The buffer used for cyclic list
    buf: [BufLen]T = undefined,
    /// end of the buffer
    end: usize = 0,

    const Self = @This();

    /// Sihft elements around so that we have a contiguous slice of active elements.
    fn emplace(self: *Self) void {
      if (self.end > Len) return;

      if (BufLen >= Len * 2 or BufLen - Len >= Len - self.end) {
        std.mem.copyBackwards(T, self.buf[Len-self.end..Len], self.buf[0..self.end]);
        @memcpy(self.buf[0..Len-self.end], self.buf[BufLen-(Len-self.end)..BufLen]);
      } else {
        std.mem.rotate(T, &self.buf, BufLen - (Len - self.end));
      }
      self.end = Len;
    }

    /// The array rotate so a contiguous slice can be return
    pub fn getSlice(self: *Self) *[Len]T {
      self.emplace();
      return self.buf[self.end-Len..][0..Len];
    }

    /// Push an element to the array. This is cheap as
    /// `self.buf` is not rotated unless `self.getSlice` is called
    pub fn push(self: *Self, val: T) void {
      self.buf[self.end] = val;
      self.end = if (self.end + 1 == self.buf.len) 0 else self.end + 1;
    }
  };
}

fn testList(Len: comptime_int, BufLen: comptime_int) !void {
  const ListType = GenPaddedCyclicList(Len, BufLen, usize);
  var list = ListType{};
  inline for (0..BufLen+(Len/2)) |i| {
    list.push(i);
  }
  
  const slice = list.getSlice();
  inline for (BufLen+(Len/2)-Len..BufLen+(Len/2), 0..) |v, i| {
    try std.testing.expect(v == slice[i]);
  }
}

test GenPaddedCyclicList {
  try testList(2, 2);
  try testList(2, 3);
  try testList(2, 4);
  try testList(2, 9);
  try testList(3, 16);

  try testList(3, 3);
  try testList(3, 4);
  try testList(5, 5);
  try testList(5, 7);
  try testList(5, 8);
  try testList(5, 9);
  try testList(5, 16);
}

