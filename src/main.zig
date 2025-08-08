const std = @import("std");
const builtin = @import("builtin");

const miniaudio = @cImport({
    @cInclude("miniaudio.h");
});

const STREAM_BUFFER_SIZE = std.math.pow(usize, 2, 16);
const FIFO_SIZE = std.math.pow(usize, 2, 20);
const START_SIZE = std.math.pow(usize, 2, 16);

const Fifo = std.fifo.LinearFifo(u8, .{ .Static = FIFO_SIZE });

const State = struct {
    alloc: std.mem.Allocator,
    fifo: Fifo,
    fifo_mutex: std.Thread.Mutex,
    net_thread: ?std.Thread,
    play_thread: ?std.Thread,
    re_stop: std.Thread.ResetEvent,
    re_start_player: std.Thread.ResetEvent,

    fn init(alloc: std.mem.Allocator) State {
        return State{
            .alloc = alloc,
            .fifo = Fifo.init(),
            .fifo_mutex = std.Thread.Mutex{},
            .net_thread = null,
            .play_thread = null,
            .re_stop = std.Thread.ResetEvent{},
            .re_start_player = std.Thread.ResetEvent{},
        };
    }

    fn deinit(self: *State) void {
        self.fifo.deinit();
    }

    fn start(self: *State) !void {
        self.re_start_player.reset();
        self.re_stop.reset();

        self.net_thread = try std.Thread.spawn(.{}, downloader, .{self});
        self.play_thread = try std.Thread.spawn(.{}, player, .{self});
        while (self.fifo.count < START_SIZE) {
            std.Thread.sleep(std.time.ns_per_ms * 20);
        }
        self.re_start_player.set();
    }

    fn stop(self: *State) void {
        self.re_stop.set();
        self.net_thread.?.join();
        self.play_thread.?.join();
        self.net_thread = null;
        self.play_thread = null;
        try self.fifo.pump(self.fifo.reader(), std.io.null_writer);
    }
};

fn read(decoder: [*c]miniaudio.ma_decoder, buf: ?*anyopaque, bytes_to_read: usize, bytes_read: [*c]usize) callconv(.c) c_int {
    bytes_read.* = bytes_to_read;

    const shared: *State = @alignCast(@ptrCast(decoder.*.pUserData.?));

    const anyopaque_pointer: *anyopaque = buf.?;
    const b: []u8 = @as([*]u8, @ptrCast(anyopaque_pointer))[0..bytes_to_read];

    shared.fifo_mutex.lock();
    const fifo_read_bytes = shared.fifo.read(b);
    shared.fifo_mutex.unlock();
    bytes_read.* = fifo_read_bytes;

    return 0;
}

fn seek(_: [*c]miniaudio.struct_ma_decoder, _: c_longlong, _: c_uint) callconv(.c) c_int {
    return 0;
}

fn downloader(state: *State) !void {
    var client = std.http.Client{ .allocator = state.alloc };
    var header_buffer: [4096]u8 = undefined;
    var readbuf: [STREAM_BUFFER_SIZE]u8 = undefined;
    const uri = try std.Uri.parse("https://stream.nightride.fm/nightride.mp3");

    var request = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    try request.send();
    try request.finish();
    try request.wait();
    std.debug.print("Status: {?}\n", .{request.response.status});

    // TODO: Wait on re_stop (timeout wait) instead on read so the thread can be terminated rapidly whatever the state of connection
    while (true) {
        if (state.re_stop.isSet()) break;
        const n = try request.read(&readbuf);
        state.fifo_mutex.lock();
        try state.fifo.write(readbuf[0..n]);
        state.fifo_mutex.unlock();
    }
    request.deinit();
    client.deinit();
}

fn player(shared: *State) !void {
    var res: miniaudio.ma_result = 0;
    const ver = miniaudio.ma_version_string();
    std.debug.print("MA Version: {s}\n", .{ver});

    var engine: miniaudio.ma_engine = miniaudio.ma_engine{};
    res = miniaudio.ma_engine_init(null, &engine);
    std.debug.print("Engine Init: {}\n", .{res});

    shared.re_start_player.wait();

    var decoder: miniaudio.ma_decoder = miniaudio.ma_decoder{};
    res = miniaudio.ma_decoder_init(read, seek, shared, null, &decoder);
    std.debug.print("Decoder Init: {}\n", .{res});

    var sound: miniaudio.ma_sound = miniaudio.ma_sound{};
    res = miniaudio.ma_sound_init_from_data_source(&engine, &decoder, miniaudio.MA_SOUND_FLAG_STREAM, null, &sound);
    std.debug.print("Sound Init: {}\n", .{res});

    _ = miniaudio.ma_sound_start(&sound);

    shared.re_stop.wait();

    _ = miniaudio.ma_sound_stop(&sound);
    _ = miniaudio.ma_sound_uninit(&sound);
    _ = miniaudio.ma_decoder_uninit(&decoder);
    _ = miniaudio.ma_engine_uninit(&engine);
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

    var state = State.init(alloc);
    defer state.deinit();

    try state.start();

    const stdin = std.io.getStdIn().reader();
    _ = try stdin.readByte();

    state.stop();
    // _ = try stdin.readByte();
    // try state.start();
    // _ = try stdin.readByte();

    // state.stop();
}
