const std = @import("std");

pub fn RingBuffer(T: type) type {
    return struct {
        head: std.atomic.Value(usize) = .init(0),
        tail: std.atomic.Value(usize) = .init(0),
        items: []T,

        pub fn init(items: []T) @This() {
            std.debug.assert(std.math.isPowerOfTwo(items.len));
            return .{ .items = items };
        }

        pub fn write(self: *@This(), values: []const T) usize {
            @setRuntimeSafety(false);

            const tail = self.tail.raw;
            const pushed = @min(values.len, self.items.len - (tail -% self.head.load(.acquire)));
            if (pushed > 0) {
                const idx = tail & (self.items.len - 1);
                const first = @min(pushed, self.items.len - idx);
                @memcpy(self.items.ptr[idx .. idx + first], values[0..first]);

                const rem = pushed - first;
                @memcpy(self.items.ptr[0..rem], values[first..rem]);
                self.tail.store(tail +% pushed, .release);
            }

            return pushed;
        }

        pub fn read(self: *@This(), values: []T) usize {
            @setRuntimeSafety(false);

            const head = self.head.raw;
            const popped = @min(values.len, self.tail.load(.acquire) -% head);
            if (popped > 0) {
                const idx = head & (self.items.len - 1);
                const first = @min(popped, self.items.len - idx);
                @memcpy(values[0..first], self.items.ptr[idx .. idx + first]);

                const rem = popped - first;
                @memcpy(values[first..rem], self.items.ptr[0..rem]);
                self.head.store(head +% popped, .release);
            }

            return popped;
        }
    };
}
