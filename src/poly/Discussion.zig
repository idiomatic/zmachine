//! The discussion: thoughts, messages, commands and changes, each with its
//! author. The latest 500 posts are kept. Its owner locks it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Discussion = @This();

posts: std.ArrayList(Post) = .empty,
next_post: u64 = 1,

const max_posts = 500;
pub const max_post = 4000;
pub const max_suggestions = 8;

pub const PostKind = enum {
    /// A partner's thinking, with any suggested commands.
    thought,
    /// A message to the other players.
    message,
    /// A command sent to the game.
    command,
    /// The mode changed; the text names the new one.
    mode,
    /// The leadership moved; the text names the new leader, or "console"
    /// for the local side.
    leader,
    /// The author joined.
    joined,
    /// The author left; the text is empty.
    left,
    /// The author kicked the player the text names.
    kicked,
    /// The author changed the password.
    password,
    /// The author let the AI partner the text names read the inspector.
    granted,
    /// The author stopped the AI partner the text names reading it.
    revoked,
};

pub const Post = struct {
    seq: u64,
    time: i64,
    /// The person's or AI partner's name, or null for the console.
    author: ?[]u8,
    ai: bool,
    kind: PostKind,
    text: []u8,
    suggestions: [][]u8,
};

pub fn deinit(d: *Discussion, gpa: Allocator) void {
    for (d.posts.items) |p| freePost(gpa, p);
    d.posts.deinit(gpa);
}

fn freePost(gpa: Allocator, p: Post) void {
    if (p.author) |name| gpa.free(name);
    for (p.suggestions) |text| gpa.free(text);
    gpa.free(p.suggestions);
    gpa.free(p.text);
}

/// Adds a post by `author` (null for the console) at `time`.
pub fn add(d: *Discussion, gpa: Allocator, time: i64, author: ?[]const u8, ai: bool, kind: PostKind, text: []const u8, suggestions: []const []const u8) !void {
    const copies = try gpa.alloc([]u8, suggestions.len);
    var copied: usize = 0;
    errdefer {
        for (copies[0..copied]) |c| gpa.free(c);
        gpa.free(copies);
    }
    for (suggestions, copies) |s, *c| {
        c.* = try gpa.dupe(u8, s);
        copied += 1;
    }
    const text_copy = try gpa.dupe(u8, text);
    errdefer gpa.free(text_copy);
    const author_copy = if (author) |n| try gpa.dupe(u8, n) else null;
    errdefer if (author_copy) |n| gpa.free(n);
    if (d.posts.items.len >= max_posts) freePost(gpa, d.posts.orderedRemove(0));
    try d.posts.append(gpa, .{
        .seq = d.next_post,
        .time = time,
        .author = author_copy,
        .ai = ai,
        .kind = kind,
        .text = text_copy,
        .suggestions = copies,
    });
    d.next_post += 1;
}

/// The sequence number of the latest post, or 0.
pub fn last(d: *const Discussion) u64 {
    return d.next_post - 1;
}
