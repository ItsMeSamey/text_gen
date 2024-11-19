const std = @import("std");

const WordGenerator = struct {
  ptr: *anyopaque,
  _gen: *fn (*anyopaque) []const u8,
  _roll: *fn (*anyopaque) void,
  _free: *fn (*anyopaque) void,

  pub fn gen(self: *WordGenerator) []const u8 {
    return self._gen(self.ptr);
  }

  pub fn roll(self: *WordGenerator) void {
    self._roll(self.ptr);
  }

  pub fn free(self: *WordGenerator) void {
    self._free(self.ptr);
  }
};


