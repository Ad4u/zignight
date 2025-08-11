const std = @import("std");
const builtin = @import("builtin");

const miniaudio = @cImport({
    @cInclude("miniaudio.h");
});

const Data = @import("data.zig");

const WAIT_TIME = std.time.ns_per_ms * 20;
const FADING_TIME = 200; // ms

const STREAM_BUFFER_SIZE = std.math.pow(usize, 2, 16);
const METADATA_BUFFER_SIZE = std.math.pow(usize, 2, 14);
const FIFO_SIZE = std.math.pow(usize, 2, 20);
const START_SIZE = std.math.pow(usize, 2, 16);

const Fifo = std.fifo.LinearFifo(u8, .{ .Static = FIFO_SIZE });

// TODO:
// Non-blocking reads (to stop threads gracefully and quickly, not waiting for read calls to return)
// Handle errors/try/catch
// log to stderr

const State = struct {
    alloc: std.mem.Allocator,
    fifo: Fifo,
    fifo_mutex: std.Thread.Mutex,
    net_thread: ?std.Thread,
    play_thread: ?std.Thread,
    update_thread: ?std.Thread,
    re_stop: std.Thread.ResetEvent,
    re_quit: std.Thread.ResetEvent,
    re_start_player: std.Thread.ResetEvent,
    stations: []Data.Station,
    stations_mutex: std.Thread.Mutex,
    active_idx: ?usize,

    fn init(alloc: std.mem.Allocator) !State {
        return State{
            .alloc = alloc,
            .fifo = Fifo.init(),
            .fifo_mutex = std.Thread.Mutex{},
            .net_thread = null,
            .play_thread = null,
            .update_thread = null,
            .re_stop = std.Thread.ResetEvent{},
            .re_quit = std.Thread.ResetEvent{},
            .re_start_player = std.Thread.ResetEvent{},
            .stations = &Data.stations_list,
            .stations_mutex = std.Thread.Mutex{},
            .active_idx = null,
        };
    }

    fn deinit(self: *State) void {
        self.fifo.deinit();
    }

    fn start_updater_thread(self: *State) !void {
        self.update_thread = try std.Thread.spawn(.{}, updater, .{self});
    }

    fn start(self: *State, idx: usize) !void {
        self.re_start_player.reset();
        self.re_stop.reset();

        self.active_idx = idx;

        self.net_thread = try std.Thread.spawn(.{}, downloader, .{self});
        self.play_thread = try std.Thread.spawn(.{}, player, .{self});
        while (self.fifo.count < START_SIZE) {
            std.Thread.sleep(std.time.ns_per_ms * WAIT_TIME);
        }
        self.re_start_player.set();
    }

    fn stop(self: *State) void {
        if (self.active_idx == null) return;

        self.re_stop.set();
        self.net_thread.?.join();
        self.play_thread.?.join();
        self.net_thread = null;
        self.play_thread = null;
        try self.fifo.pump(self.fifo.reader(), std.io.null_writer);
        self.active_idx = null;
    }

    fn quit(self: *State) void {
        self.stop();
        self.re_quit.set();
        self.update_thread.?.join();
        self.update_thread = null;
    }

    fn updateStations(state: *State, new: Data.ParsedData) void {
        std.debug.print("STATION UPDATE - {s} - {s} - {s}\n", .{ new.station, new.artist, new.title });
        for (state.stations) |*station| {
            if (std.mem.eql(u8, station.meta_name, new.station)) {
                state.stations_mutex.lock();
                station.artist = new.artist;
                station.title = new.title;
                state.stations_mutex.unlock();
                break;
            }
        }
    }
};

fn updater(state: *State) !void {
    const meta_url = "https://nightride.fm/meta";

    var client = std.http.Client{ .allocator = state.alloc };
    var header_buffer: [4096]u8 = undefined;
    var readbuf: [METADATA_BUFFER_SIZE]u8 = undefined;
    const uri = try std.Uri.parse(meta_url);

    var request = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    try request.send();
    try request.finish();
    try request.wait();
    std.debug.print("Meta Status: {?}\n", .{request.response.status});

    while (true) {
        if (state.re_quit.isSet()) break;
        const line = try request.reader().readUntilDelimiter(&readbuf, '\n');
        if (line.len == 0) continue;
        const json_slice = line[7 .. line.len - 1];
        const parsed = std.json.parseFromSlice(Data.ParsedData, state.alloc, json_slice, .{ .ignore_unknown_fields = true }) catch continue;
        state.updateStations(parsed.value);
        parsed.deinit();
    }
    request.deinit();
    client.deinit();
}

fn downloader(state: *State) !void {
    var client = std.http.Client{ .allocator = state.alloc };
    var header_buffer: [4096]u8 = undefined;
    var readbuf: [STREAM_BUFFER_SIZE]u8 = undefined;
    const uri = try std.Uri.parse(state.stations[state.active_idx.?].url);

    var request = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    try request.send();
    try request.finish();
    try request.wait();
    std.debug.print("Stream Status: {?}\n", .{request.response.status});

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

    miniaudio.ma_sound_set_fade_in_milliseconds(&sound, 0, 1, FADING_TIME);
    _ = miniaudio.ma_sound_start(&sound);

    shared.re_stop.wait();

    miniaudio.ma_sound_set_fade_in_milliseconds(&sound, 1, 0, FADING_TIME);
    std.Thread.sleep(std.time.ns_per_ms * FADING_TIME);
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

    var state = try State.init(alloc);
    defer state.deinit();
    try state.start_updater_thread();

    try state.start(0);

    const stdin = std.io.getStdIn().reader();
    _ = try stdin.readByte();

    state.quit();

    // state.stop();
    // _ = try stdin.readByte();
    // try state.start(1);
    // _ = try stdin.readByte();

    // state.stop();
}
