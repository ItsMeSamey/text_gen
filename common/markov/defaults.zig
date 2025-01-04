const std = @import("std");

pub const Endian = std.builtin.Endian.little;

// the Integer type to represent the key in a the markov chain
pub const CharKey = u8;
pub const WordKey = u32;

// The Type used to store the frequency of occurrence
pub const Val = u16;

