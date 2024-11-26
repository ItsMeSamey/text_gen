const std = @import("std");

fn GetConverter(T: type, _gen: fn(*T) []const u8, _roll: ?fn(*T) void, _free: ?fn(*T) void) type {
  return struct {
    pub fn gen(ptr: *anyopaque) []const u8 {
      return _gen(@ptrCast(@alignCast(ptr)));
    }

    pub fn roll(ptr: *anyopaque) void {
      if (_roll) |rollFn| rollFn(@ptrCast(@alignCast(ptr)));
    }

    pub fn free(ptr: *anyopaque) void {
      if (_free) |freeFn| freeFn(@ptrCast(@alignCast(ptr)));
    }
  };
}

pub const WordGenerator = struct {
  ptr: *anyopaque,
  _gen: *const fn (*anyopaque) []const u8,
  _roll: *const fn (*anyopaque) void,
  _free: *const fn (*anyopaque) void,

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

pub fn fromGenWords(genWords: anytype) WordGenerator {
  const generatorType = @typeInfo(@TypeOf(genWords)).pointer.child;
  const converter = GetConverter(generatorType, generatorType.gen, null, generatorType.free);
  return WordGenerator{
    .ptr = @ptrCast(genWords),
    ._gen = converter.gen,
    ._roll = converter.roll,
    ._free = converter.free,
  };
}

pub fn fromGenMarkov(genMarkov: anytype) WordGenerator {
  const generatorType = @typeInfo(@TypeOf(genMarkov)).pointer.child;
  const converter = GetConverter(generatorType, generatorType.gen, generatorType.roll, generatorType.free);
  return WordGenerator{
    .ptr = @ptrCast(genMarkov),
    ._gen = converter.gen,
    ._roll = converter.roll,
    ._free = converter.free,
  };
}

