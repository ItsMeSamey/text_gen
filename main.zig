const std = @import("std");
const Markov = @import("trainMarkov.zig");
const CharMakov = Markov.CharMakov;
const WordMakov = Markov.WordMakov;

fn readAllMerged(allocator: std.mem.Allocator, dir: std.fs.Dir) ![]u8 {
  var walker = try dir.walk(allocator);
  defer walker.deinit();

  var files = std.ArrayListUnmanaged(std.fs.File){};
  defer {
    for (files.items) |*file| file.close();
    files.deinit(allocator);
  }

  var size: usize = 0;
  while (try walker.next()) |entry| {
    var file = try entry.dir.openFile(entry.basename, .{});
    const stats = try file.stat();
    size += stats.size + 1; // +1 for the extra newline
    try files.append(allocator, file);
  }

  var memory = try allocator.alloc(u8, size);
  errdefer allocator.free(memory);

  size = 0;
  for (files.items) |file| {
    const n = try file.readAll(memory[size..]);
    std.debug.assert(n < memory[size..].len);
    size += n;
    memory[size] = '\n';
    size += 1;
  }

  std.debug.assert(size == memory.len);
  return memory;
}

fn filterAllowed(str: []u8) []u8 {
  var idx: usize = 0;
  var encountered: bool = false;
  for (str) |char_| {
    const char = std.ascii.toLower(char_);
    if (
      (char >= 'a' and char <= 'z') or
      (char >= '0' and char <= '9')
    ) {
      if (encountered) {
        encountered = false;
        str[idx] = '\x00';
        idx += 1;
      }
      str[idx] = char;
      idx += 1;
    } else {
      switch (char) {
        '\'' => {},
        else => {
          encountered = true;
        },
      }
    }
  }

  return str[0..idx];
}

pub fn main() !void {
  var gpa = std.heap.GeneralPurposeAllocator(.{}){};
  defer _ = gpa.deinit();
  const allocator = gpa.allocator();

  var data_dir = try std.fs.cwd().openDir("data", .{});
  defer data_dir.close();

  var markov_dir = try data_dir.openDir("markov", .{ .iterate = true, .no_follow = true });
  defer markov_dir.close();

  const file_text = try readAllMerged(allocator, markov_dir);
  defer allocator.free(file_text);
  const training_data = filterAllowed(file_text);

  // std.debug.print("Training data: {s}\n", .{file_text});
  var timer = try std.time.Timer.start();

  { // Train word makov model
    var makov = try WordMakov(4).init(allocator);
    defer makov.deinit();
    timer.reset();
    try makov.train(training_data);
    std.debug.print("Word Makov took {d}ms\n", .{@as(f128, @floatFromInt(timer.read()))/@as(f128, @floatFromInt(std.time.ns_per_ms))});

    var markov_file = try data_dir.createFile("markov.word", .{});
    defer markov_file.close();

    var buffered = std.io.bufferedWriter(markov_file.writer().any());
    timer.reset();
    try makov.write(buffered.writer().any());
    try buffered.flush();
    std.debug.print("Word Makov write took {d}ms\n", .{@as(f128, @floatFromInt(timer.read()))/@as(f128, @floatFromInt(std.time.ns_per_ms))});
  }

  { // Train char makov model
    var makov = try CharMakov(8).init(allocator);
    defer makov.deinit();
    timer.reset();
    try makov.train(training_data);
    std.debug.print("Char Makov took {d}ms\n", .{@as(f128, @floatFromInt(timer.read()))/@as(f128, @floatFromInt(std.time.ns_per_ms))});

    var markov_file = try data_dir.createFile("markov.char", .{});
    defer markov_file.close();

    var buffered = std.io.bufferedWriter(markov_file.writer().any());
    timer.reset();
    try makov.write(buffered.writer().any());
    try buffered.flush();
    std.debug.print("Char Makov write took {d}ms\n", .{@as(f128, @floatFromInt(timer.read()))/@as(f128, @floatFromInt(std.time.ns_per_ms))});
  }
}


