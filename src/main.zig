const std = @import("std");
const builtin = @import("builtin");
const log = std.log;

const miniaudio = @cImport({
    @cInclude("miniaudio.h");
});

const Data = @import("data.zig");

const WAIT_TIME = std.time.ns_per_ms * 20;
const FADING_TIME = 50; // ms

const STREAM_BUFFER_SIZE = std.math.pow(usize, 2, 16);
const METADATA_BUFFER_SIZE = std.math.pow(usize, 2, 14);
const FIFO_SIZE = std.math.pow(usize, 2, 20);
const START_SIZE = std.math.pow(usize, 2, 16);

const Fifo = std.fifo.LinearFifo(u8, .{ .Static = FIFO_SIZE });

// TODO:
// Handle errors in miniaudio thread from miniaudio
// Handle logic error if playing/stopping too fast (like hit play while stopping joining for faders)

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
        log.debug("Starting Updater thread", .{});
        self.update_thread = try std.Thread.spawn(.{}, updater, .{self});
        log.debug("Updater thread Started", .{});
    }

    fn start(self: *State, idx: usize) !void {
        log.debug("Starting threads for streaming", .{});
        log.debug("Requested station - idx: {} - name: {s}", .{ idx, self.stations[idx].name });
        self.active_idx = idx;

        self.net_thread = try std.Thread.spawn(.{}, downloader, .{self});
        self.play_thread = try std.Thread.spawn(.{}, player, .{self});
        log.debug("Net and Play threads spawned. Waiting for buffer to be filled", .{});
        while (self.fifo.count < START_SIZE) {
            std.Thread.sleep(WAIT_TIME);
        }
        log.debug("Buffer filled. Setting the Event for the player.", .{});
        self.re_start_player.set();
    }

    fn stop(self: *State) void {
        log.debug("Stop requested", .{});
        if (self.active_idx == null) return;

        self.re_stop.set();
        log.debug("Joining threads", .{});
        self.net_thread.?.join();
        self.play_thread.?.join();
        self.net_thread = null;
        self.play_thread = null;
        log.debug("Threads joined. Emptying the stream buffer", .{});
        self.fifo.pump(self.fifo.reader(), std.io.null_writer) catch |err| {
            log.err("An error occured while emptying the stream buffer: {s}\n", .{@errorName(err)});
            self.quit();
            std.process.exit(1);
        };
        self.active_idx = null;

        self.re_start_player.reset();
        self.re_stop.reset();
        log.debug("Streaming stopped", .{});
    }

    fn quit(self: *State) void {
        log.debug("Quit requested", .{});
        self.re_quit.set();

        log.debug("Joining Updater thread", .{});
        self.update_thread.?.join();
        self.update_thread = null;
        log.debug("Thread joined. Quit process finished", .{});
    }

    fn updateStations(state: *State, new: Data.ParsedData) void {
        log.info("Update station: {s} - artist: {s} - title: {s}", .{ new.station, new.artist, new.title });
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
    const tlog = log.scoped(.updater);
    const meta_url = "https://nightride.fm/meta";

    tlog.debug("Updater thread spawned", .{});
    var client = std.http.Client{ .allocator = state.alloc };
    var header_buffer: [4096]u8 = undefined;
    var readbuf: [METADATA_BUFFER_SIZE]u8 = undefined;
    const uri = std.Uri.parse(meta_url) catch unreachable;

    tlog.debug("Opening http connection", .{});
    var request = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    try request.send();
    try request.finish();
    try request.wait();
    tlog.debug("http status: {?}", .{request.response.status});

    var polls: [1]std.posix.pollfd = undefined;
    polls[0] = .{
        .fd = request.connection.?.stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };

    tlog.debug("Starting the continuous polling", .{});
    var buf_len: usize = 0;
    while (true) {
        if (state.re_quit.isSet()) break;

        buf_len = 0;
        while (try std.posix.poll(&polls, 20) > 0) {
            const bytes_read = try request.read(readbuf[buf_len..]);
            buf_len += bytes_read;
        }

        if (buf_len == 0) continue;

        var lines = std.mem.tokenizeScalar(u8, readbuf[0..buf_len], '\n');
        while (lines.next()) |line| {
            if (line.len == 0) continue;
            const json_slice = line[7 .. line.len - 1];
            const parsed = std.json.parseFromSlice(Data.ParsedData, state.alloc, json_slice, .{ .ignore_unknown_fields = true }) catch continue;
            state.updateStations(parsed.value);
            parsed.deinit();
        }
    }

    tlog.debug("Loop breaked by quit event", .{});
    request.deinit();
    client.deinit();
    tlog.debug("Resources freed. Exiting thread", .{});
}

fn downloader(state: *State) !void {
    const tlog = log.scoped(.downloader);
    tlog.debug("Downloader thread spawned", .{});

    var client = std.http.Client{ .allocator = state.alloc };
    var header_buffer: [4096]u8 = undefined;
    var readbuf: [STREAM_BUFFER_SIZE]u8 = undefined;
    const uri = std.Uri.parse(state.stations[state.active_idx.?].url) catch unreachable;

    tlog.debug("Opening http connection", .{});
    var request = try client.open(.GET, uri, .{ .server_header_buffer = &header_buffer });
    try request.send();
    try request.finish();
    try request.wait();
    tlog.debug("http status: {?}", .{request.response.status});

    var polls: [1]std.posix.pollfd = undefined;
    polls[0] = .{
        .fd = request.connection.?.stream.handle,
        .events = std.posix.POLL.IN,
        .revents = 0,
    };

    tlog.debug("Starting the continuous polling", .{});
    while (true) {
        if (state.re_stop.isSet()) break;

        if (try std.posix.poll(&polls, 20) > 0) {
            const bytes_read = try request.read(&readbuf);
            state.fifo_mutex.lock();
            try state.fifo.write(readbuf[0..bytes_read]);
            state.fifo_mutex.unlock();
        }
    }

    tlog.debug("Loop breaked by stop event", .{});
    request.deinit();
    client.deinit();
    tlog.debug("Resources freed. Exiting thread", .{});
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
    const tlog = log.scoped(.player);
    tlog.debug("Player thread spawned", .{});

    var res: miniaudio.ma_result = 0;

    tlog.debug("Initializing engine", .{});
    var engine: miniaudio.ma_engine = miniaudio.ma_engine{};
    res = miniaudio.ma_engine_init(null, &engine);
    tlog.debug("Engine init output: {}", .{res});

    tlog.debug("Waiting for buffer to be filled", .{});
    shared.re_start_player.wait();

    tlog.debug("Buffer filled. Initializing decoder", .{});
    var decoder: miniaudio.ma_decoder = miniaudio.ma_decoder{};
    res = miniaudio.ma_decoder_init(read, seek, shared, null, &decoder);
    tlog.debug("Decoder init output: {}", .{res});

    tlog.debug("Initializing sound", .{});
    var sound: miniaudio.ma_sound = miniaudio.ma_sound{};
    res = miniaudio.ma_sound_init_from_data_source(&engine, &decoder, miniaudio.MA_SOUND_FLAG_STREAM, null, &sound);
    tlog.debug("Sound init output: {}", .{res});

    tlog.debug("Starting sound", .{});
    miniaudio.ma_sound_set_fade_in_milliseconds(&sound, 0, 1, FADING_TIME);
    res = miniaudio.ma_sound_start(&sound);
    tlog.debug("Sound started", .{});

    shared.re_stop.wait();
    tlog.debug("Received stop event. Stopping sound", .{});

    miniaudio.ma_sound_set_fade_in_milliseconds(&sound, 1, 0, FADING_TIME);
    std.Thread.sleep(std.time.ns_per_ms * FADING_TIME);
    res = miniaudio.ma_sound_stop(&sound);
    tlog.debug("Sound stopped. Output: {}", .{res});

    tlog.debug("Deinit Miniaudio resources", .{});
    miniaudio.ma_sound_uninit(&sound);
    res = miniaudio.ma_decoder_uninit(&decoder);
    miniaudio.ma_engine_uninit(&engine);
    tlog.debug("Miniaudio resources freed. Exiting thread", .{});
}

pub fn main() void {
    var debug_allocator: std.heap.DebugAllocator(.{}) = .init;
    const alloc = switch (builtin.mode) {
        .Debug, .ReleaseSafe => debug_allocator.allocator(),
        .ReleaseFast, .ReleaseSmall => std.heap.smp_allocator,
    };

    defer if (builtin.mode == .Debug or builtin.mode == .ReleaseSafe) {
        _ = debug_allocator.deinit();
    };

    var state = State.init(alloc) catch |err| {
        log.err("Couldn't initialize application: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };
    defer state.deinit();

    state.start_updater_thread() catch |err| {
        log.err("Couldn't launch Updater thread: {s}\n", .{@errorName(err)});
        std.process.exit(1);
    };

    state.start(0) catch |err| {
        log.err("Couldn't start the stream: {s}\n", .{@errorName(err)});
    };

    const stdin = std.io.getStdIn().reader();
    _ = stdin.readByte() catch unreachable;

    state.stop();
    state.quit();
}
