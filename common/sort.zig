/// functions from std.sort but generalized

const std = @import("std");

pub fn partitionPoint(from: usize, to: usize, context: anytype) usize {
  var low: usize = from;
  var high: usize = to;

  while (low < high) {
    const mid = low + (high - low) / 2;
    if (context.predicate(mid)) {
      low = mid + 1;
    } else {
      high = mid;
    }
  }
  return low;
}

pub fn lowerBound(from: usize, to: usize, context: anytype) usize {
  return partitionPoint(from, to, struct {
    sub_ctx: @TypeOf(context),
    pub fn predicate(self: @This(), index: usize) bool {
      if ((@hasDecl(@TypeOf(context), "greaterThan"))) {
        return self.sub_ctx.greaterThan(index);
      } else {
        return self.sub_ctx.compareFn(index) == .gt;
      }
    }
  }{
    .sub_ctx = context,
  });
}

pub fn upperBound(from: usize, to: usize, context: anytype) usize {
  return partitionPoint(from, to, struct {
    sub_ctx: @TypeOf(context),
    pub fn predicate(self: @This(), index: usize) bool {
      if ((@hasDecl(@TypeOf(context), "lessThan"))) {
        return !self.sub_ctx.lessThan(index);
      } else {
        return self.sub_ctx.compareFn(index) != .lt;
      }
    }
  }{
    .sub_ctx = context,
  });
}

pub fn equalRange(from: usize, to: usize, context: anytype) struct { usize, usize } {
  var low: usize = from;
  var high: usize = to;

  while (low < high) {
    const mid = low + (high - low) / 2;
    switch (context.compareFn(mid)) {
      .gt => {
        low = mid + 1;
      },
      .lt => {
        high = mid;
      },
      .eq => {
        return .{
          lowerBound(low, mid, context),
          upperBound(mid, high, context),
        };
      },
    }
  }

  return .{ low, low };
}

