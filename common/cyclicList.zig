const std = @import("std");

/// Make a cyclic list with a list of given type T
/// Use `len` = `0` if you want to have slice buffer you can assign at runtime 
pub fn GenCyclicList(len: comptime_int, T: type) type {
  const bufType = if (len == 0) []T else [len]T;
  return struct {
    _buf: bufType = undefined,
    _at: usize = 0,

    const Self = @This();

    pub fn init(buf: []T) Self {
      return .{
        ._buf = buf,
        ._at = 0,
      };
    }

    fn emplace(self: *Self) void {
      if (self._at != self._buf.len - 1) return;
      std.mem.rotate(T, self._buf, self._buf.len - (1 + self._at));
      self._at = self._buf.len - 1;
    }

    pub fn getSlice(self: *Self) bufType {
      self.emplace();
      return self._buf;
    }

    pub fn push(self: *Self, val: T) void {
      self._buf[self._at] = val;
      self._at = if (self._at + 1 == self._buf.len) 0 else self._at + 1;
    }
  };
}

