const std = @import("std");
const Value = std.atomic.Value;

// https://ziglang.org/documentation/0.16.0/std/#std.atomic.Value
const RefCount = @This();
count: Value(usize),
dropFn: *const fn (rc: *RefCount) void,

pub fn ref(rc: *RefCount) void {
    // no synchronization necessary; just updating a counter.
    _ = rc.count.fetchAdd(1, .monotonic);
}

pub fn unref(rc: *RefCount) void {
    // release ensures code before unref() happens-before the
    // count is decremented as dropFn could be called by then.
    if (rc.count.fetchSub(1, .release) == 1) {
        // seeing 1 in the counter means that other unref()s have happened,
        // but it doesn't mean that uses before each unref() are visible.
        // The load acquires the release-sequence created by previous unref()s
        // in order to ensure visibility of uses before dropping.
        _ = rc.count.load(.acquire);
        (rc.dropFn)(rc);
    }
}

pub fn noop(_: *RefCount) void {}

const testing = std.testing;
test "ref count" {
    var ref_count: RefCount = .{
        .count = Value(usize).init(0),
        .dropFn = RefCount.noop,
    };
    ref_count.ref();
    ref_count.unref();
}

test "ref count context" {
    const UseRefCount = struct {
        freed: bool,
        rc: RefCount,
        const Self = @This();
        fn free(rc: *RefCount) void {
            var self: *Self = @fieldParentPtr("rc", rc);
            self.freed = true;
        }
    };
    var ctx = UseRefCount{
        .freed = false,
        .rc = .{
            .count = Value(usize).init(0),
            .dropFn = UseRefCount.free,
        },
    };
    ctx.rc.ref();
    ctx.rc.ref();
    ctx.rc.unref();
    ctx.rc.ref();
    ctx.rc.unref();
    try testing.expect(!ctx.freed);

    ctx.rc.unref();
    try testing.expect(ctx.freed);
}
