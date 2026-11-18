//! Repro: counts over 65 535 (tags, sentences in a paragraph) must be refused by
//! `tilla.build` with an error, not crash the build. tilla.md stores each count in a u16.

const std = @import("std");
const tilla = @import("tilla");

/// A pt-BR translation of an Italian story, otherwise valid: the dict is never opened.
fn base() !tilla.Input {
    return .{
        .lang = try .fromText("pt-BR"),
        .original = try .fromText("it"),
        .title = "A casa",
        .subtitle = "Uma história",
        .paragraphs = &.{&.{"Casa."}},
    };
}

test "AC-8: 65 536 tags are refused with an error instead of crashing the build" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const tags = try arena.allocator().alloc([]const u8, 65536);
    @memset(tags, "t");
    var in = try base();
    in.tags = tags;
    if (tilla.build(arena.allocator(), in, "unused.db")) |_| {
        return error.TestExpectedError;
    } else |_| {}
}

test "AC-8: one paragraph of 65 536 word-less sentences is refused with an error instead of crashing" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sentences = try arena.allocator().alloc([]const u8, 65536);
    @memset(sentences, "—");
    const paragraphs: []const []const []const u8 = &.{sentences};
    var in = try base();
    in.paragraphs = paragraphs;
    if (tilla.build(arena.allocator(), in, "unused.db")) |_| {
        return error.TestExpectedError;
    } else |_| {}
}
