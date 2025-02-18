const std = @import("std");

pub fn GetConverter(T: type, _gen: fn(*T) []const u8, _roll: ?fn(*T) void, _free: ?fn(*T) void) type {
  return struct {
    pub fn gen(ptr: *anyopaque) []const u8 { return _gen(@ptrCast(@alignCast(ptr))); }
    pub fn roll(ptr: *anyopaque) void { _roll.?(@ptrCast(@alignCast(ptr))); }
    pub fn free(ptr: *anyopaque) void { _free.?(@ptrCast(@alignCast(ptr))); }

    pub fn any(ptr: *T) WordGenerator {
      return .{
        .ptr = @ptrCast(ptr),
        ._gen =  gen,
        ._roll = if (_roll) roll else null,
        ._free = if (_free) free else null,
      };
    }
  };
}

pub const WordGenerator = struct {
  ptr: *anyopaque,
  _gen: *const fn (*anyopaque) []const u8,
  _roll: ?*const fn (*anyopaque) void,
  _free: ?*const fn (*anyopaque) void,

  pub fn gen(self: @This()) []const u8 { return self._gen(self.ptr); }
  pub fn roll(self: @This()) void { if (self._roll) |rollFn| rollFn(self.ptr); }
  pub fn free(self: @This()) void { if (self._free) |freeFn| freeFn(self.ptr); }
};

pub fn autoConvert(ptr: anytype) WordGenerator {
  const T = std.meta.Child(@TypeOf(ptr));
  return GetConverter(
    T,
    if (@hasDecl(T, "gen"))  @field(T, "gen")  else @compileError("No `gen` field found in type " ++ @typeName(T)),
    if (@hasDecl(T, "roll")) @field(T, "roll") else null,
    if (@hasDecl(T, "free")) @field(T, "free") else null,
  ).any(ptr);
}

pub fn autoConvertInterface(ptr: anytype) WordGenerator {
  return WordGenerator{
    .ptr = ptr.ptr,
    ._gen = ptr._gen,
    ._roll = if (@hasField(ptr, "_roll")) ptr._roll else null,
    ._free = if (@hasField(ptr, "_free")) ptr._free else null,
  };
}

