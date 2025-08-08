const std = @import("std");
const builtin = @import("builtin");

const miniaudio = @cImport({
    @cInclude("miniaudio.h");
});

const FIFO_SIZE = std.math.pow(usize, 2, 20);
const START_SIZE = std.math.pow(usize, 2, 16);

// TODO:
// - Use a big 'shared' struct for synchronization with many mutexes/ResetEvent etc.
// - Handle radio change: stop sound, clear fifo (discard count), play sound after ring buffer ok.
// - Handle leaks ? Take thread handles, send 'quit' event to stop the thread, join before exiting.
// - Change Fifo to RingBuffer

const Shared = struct {
    fifo: std.fifo.LinearFifo(u8, .{ .Static = FIFO_SIZE }),
    mutex: std.Thread.Mutex,
    alloc: std.mem.Allocator,
    event: ?Events,
};

const Events = enum {
    play,
    stop,
    quit,
};

fn read(decoder: [*c]miniaudio.ma_decoder, buf: ?*anyopaque, bytes_to_read: usize, bytes_read: [*c]usize) callconv(.c) c_int {
    bytes_read.* = bytes_to_read;

    const shared: *Shared = @alignCast(@ptrCast(decoder.*.pUserData.?));

    const anyopaque_pointer: *anyopaque = buf.?;
    const b: []u8 = @as([*]u8, @ptrCast(anyopaque_pointer))[0..bytes_to_read];

    // shared.mutex.lock();
    const fifo_read_bytes = shared.fifo.read(b);
    // shared.mutex.unlock();
    bytes_read.* = fifo_read_bytes;

    return 0;
}

fn seek(_: [*c]miniaudio.struct_ma_decoder, _: c_longlong, _: c_uint) callconv(.c) c_int {
    return 0;
}

fn download(s: *Shared) !void {
    var client = std.http.Client{ .allocator = s.alloc };
    var header_buffer: [4096]u8 = undefined;
    const uri = try std.Uri.parse("https://stream.nightride.fm/nightride.mp3");
    var request = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });

    try request.send();
    try request.finish();

    try request.wait();

    std.debug.print("Status: {?}\n", .{request.response.status});
    var readbuf: [65536]u8 = undefined;

    while (true) {
        const n = try request.read(&readbuf);
        // s.mutex.lock();
        try s.fifo.write(readbuf[0..n]);
        // s.mutex.unlock();
    }
    request.deinit();
}

fn player(shared: *Shared) !void {
    var res: miniaudio.ma_result = 0;
    const ver = miniaudio.ma_version_string();
    std.debug.print("MA Version: {s}\n", .{ver});

    var engine: miniaudio.ma_engine = miniaudio.ma_engine{};
    res = miniaudio.ma_engine_init(null, &engine);
    std.debug.print("Engine Init: {}\n", .{res});

    var decoder: miniaudio.ma_decoder = miniaudio.ma_decoder{};
    res = miniaudio.ma_decoder_init(read, seek, shared, null, &decoder);
    std.debug.print("Decoder Init: {}\n", .{res});

    var sound: miniaudio.ma_sound = miniaudio.ma_sound{};
    res = miniaudio.ma_sound_init_from_data_source(&engine, &decoder, miniaudio.MA_SOUND_FLAG_STREAM, null, &sound);
    std.debug.print("Sound Init: {}\n", .{res});

    _ = miniaudio.ma_sound_start(&sound);

    while (true) {
        std.Thread.sleep(std.time.ns_per_ms * 500);
    }
}

pub fn main() !void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const alloc = switch (builtin.mode) {
        .Debug, .ReleaseSafe => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };

    defer if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        _ = debug_allocator.deinit();
    };

    var fifo = std.fifo.LinearFifo(u8, .{ .Static = FIFO_SIZE }).init();
    defer fifo.deinit();
    const mutex = std.Thread.Mutex{};
    var shared = Shared{ .fifo = fifo, .mutex = mutex, .alloc = alloc, .event = null };

    _ = try std.Thread.spawn(.{}, download, .{&shared});

    while (shared.fifo.count < START_SIZE) {
        std.Thread.sleep(std.time.ns_per_ms * 10);
    }
    // shared.event = .play;
    _ = try std.Thread.spawn(.{}, player, .{&shared});

    const stdin = std.io.getStdIn().reader();
    _ = try stdin.readByte();
}
