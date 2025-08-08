const std = @import("std");

const BASE_URL = "https://stream.nightride.fm/";

pub const ParsedData = struct {
    station: []const u8,
    title: []const u8,
    artist: []const u8,
};

pub const Station = struct {
    meta_name: []const u8,
    name: []const u8,
    artist: []const u8 = "",
    title: []const u8 = "",
    url: []const u8,
};

pub var stations_list = [_]Station{ Station{
    .meta_name = "nightride",
    .name = "NightRide",
    .url = BASE_URL ++ "nightride" ++ ".mp3",
}, Station{
    .meta_name = "chillsynth",
    .name = "ChillSynth",
    .url = BASE_URL ++ "chillsynth" ++ ".mp3",
}, Station{
    .meta_name = "datawave",
    .name = "DataWave",
    .url = BASE_URL ++ "datawave" ++ ".mp3",
}, Station{
    .meta_name = "spacesynth",
    .name = "SpaceSynth",
    .url = BASE_URL ++ "spacesynth" ++ ".mp3",
}, Station{
    .meta_name = "darksynth",
    .name = "DarkSynth",
    .url = BASE_URL ++ "darksynth" ++ ".mp3",
}, Station{
    .meta_name = "horrorsynth",
    .name = "HorrorSynth",
    .url = BASE_URL ++ "horrorsynth" ++ ".mp3",
}, Station{
    .meta_name = "ebsm",
    .name = "EBSM",
    .url = BASE_URL ++ "ebsm" ++ ".mp3",
}, Station{
    .meta_name = "rekt",
    .name = "Rekt",
    .url = BASE_URL ++ "rekt" ++ ".mp3",
}, Station{
    .meta_name = "rektory",
    .name = "Rektory",
    .url = BASE_URL ++ "rektory" ++ ".mp3",
} };
