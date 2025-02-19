const std = @import("std");

/// Give a type, make it optional if it isn't already
pub fn Optional(comptime T: type) type {
  return switch (@typeInfo(T)) {
    .optional => T,
    else => @Type(.{ .optional = .{.child = T} }),
  };
}

/// Returns a new struct with same fields as input type but all of them are optional
pub fn OptionalStruct(comptime T: type) type {
  const info = @typeInfo(T).@"struct";
  comptime var fields: []const std.builtin.Type.StructField = &.{};

  for (info.fields) |f| {
    const optionalFtype = Optional(f.type);
    fields = fields ++ [_]std.builtin.Type.StructField{
      .{
        .name = f.name,
        .type = optionalFtype,
        .default_value_ptr = @ptrCast(
          &@as(optionalFtype, null) // This should be fine as address is taken at comptime
        ),
        .is_comptime = f.is_comptime,
        .alignment = f.alignment,
      }
    };
  }
  return @Type(.{
    .@"struct" = .{
      .layout = info.layout,
      .backing_integer = info.backing_integer,
      .fields = fields,
      .decls = info.decls,
      .is_tuple = info.is_tuple,
    }
  });
}

test {
  const S = struct {
    a: u8,
  };

  const So = OptionalStruct(S);
  std.debug.assert((So{}).a == null);
}

