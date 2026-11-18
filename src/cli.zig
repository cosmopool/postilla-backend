//! postilla: the authoring CLI (specification.md, The CLI). Each command works on one
//! story folder. The commands come with their slices; this is only the entry point.

const std = @import("std");

const usage =
    \\usage: postilla <command> <folder>
    \\
    \\  translate <folder> [--force] [--redo <lang>]   moderate the Italian, translate the missing languages
    \\  narrate   <folder>                             narrate every language with target 1
    \\  publish   <folder>                             build the .tilla files, upload to R2, POST /stories
    \\
;

pub fn main(init: std.process.Init) !void {
    _ = init;
    std.debug.print("{s}", .{usage});
    std.process.exit(2);
}
