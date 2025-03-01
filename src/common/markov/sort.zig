/// functions from std.sort but generalized

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
      return self.sub_ctx.compareFn(index).invert() == .lt;
    }
  }{
    .sub_ctx = context,
  });
}

pub fn upperBound(from: usize, to: usize, context: anytype) usize {
  return partitionPoint(from, to, struct {
    sub_ctx: @TypeOf(context),
    pub fn predicate(self: @This(), index: usize) bool {
      return self.sub_ctx.compareFn(index).invert() != .gt;
    }
  }{
    .sub_ctx = context,
  });
}

/// Returns a tuple of the lower and upper indices in `items` between which all
/// elements return `.eq` when given to `compareFn`.
/// - If no element in `items` returns `.eq`, both indices are the
/// index of the first element in `items` returning `.gt`.
/// - If no element in `items` returns `.gt`, both indices equal `items.len`.
///
/// `items` must be sorted in ascending order with respect to `compareFn`:
/// ```
/// [0]                                                   [len]
/// ┌───┬───┬─/ /─┬───┬───┬───┬─/ /─┬───┬───┬───┬─/ /─┬───┐
/// │.lt│.lt│ \ \ │.lt│.eq│.eq│ \ \ │.eq│.gt│.gt│ \ \ │.gt│
/// └───┴───┴─/ /─┴───┴───┴───┴─/ /─┴───┴───┴───┴─/ /─┴───┘
/// ├─────────────────┼─────────────────┼─────────────────┤
///  ↳ zero or more    ↳ zero or more    ↳ zero or more
///                   ├─────────────────┤
///                    ↳ returned range
/// ```
///
/// `O(log n)` time complexity.
///
/// See also: `lowerBound, `upperBound`, `partitionPoint`.
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

