const std = @import("std");
const words_zig = @import("src/words.zig");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{});
    const optimize = b.standardOptimizeOption(.{});
    const test_file = b.option([]const u8, "test-file", "Run only this test file (test/<name>.zig)");
    const coverage = b.option(bool, "coverage", "Run the tests under kcov, into coverage/kcov") orelse false;

    const words = b.addModule("words", .{ .root_source_file = b.path("src/words.zig") });
    // A package that imports only `words` needs nothing below, so it never fetches SQLite.
    if (!b.isRoot()) return;

    // The app's normalization, from the same source: the letter table read through
    // `words.normalize`, then `normalize` and `lookupKeys` in Dart.
    var table: []const u8 = "";
    var cp: u21 = 0xC0;
    while (cp <= 0x24F) : (cp += 1) {
        var letter: [2]u8 = undefined;
        var norm: [2]u8 = undefined;
        const r = words_zig.normalize(letter[0 .. std.unicode.utf8Encode(cp, &letter) catch unreachable], &norm);
        if (std.ascii.isLower(r[0])) table = b.fmt("{s}  0x{x}: '{s}',\n", .{ table, cp, r });
    }
    const dart = b.addWriteFiles().add("words_norm.dart", b.fmt("{s}{s}{s}", .{ dart_head, table, dart_tail }));
    b.step("dart", "Write the app's normalization to zig-out/dart/words_norm.dart")
        .dependOn(&b.addInstallFileWithDir(dart, .prefix, "dart/words_norm.dart").step);

    // SQLite, vendored as the amalgamation. Multi-thread mode (2): every thread opens its
    // own connection, and no connection is shared between threads.
    const sqlite_dir = (b.lazyDependency("sqlite", .{}) orelse return).path("");
    const c = b.addTranslateC(.{
        .root_source_file = b.path("src/c.h"),
        .target = target,
        .optimize = optimize,
    });
    c.addIncludePath(sqlite_dir);
    const c_mod = c.createModule();

    const server_mod = module(b, "src/server.zig", target, optimize, c_mod, sqlite_dir);
    // `tilla` reaches SQLite and the wire types through `server.db` and `server.wire`.
    const tilla = b.createModule(.{ .root_source_file = b.path("src/tilla.zig"), .imports = &.{
        .{ .name = "c", .module = c_mod },
        .{ .name = "server", .module = server_mod },
        .{ .name = "words", .module = words },
    } });
    // A file belongs to one module, so `outbound.zig` is its own, imported by that name.
    const outbound = b.createModule(.{ .root_source_file = b.path("src/outbound.zig") });
    const r2 = b.createModule(.{ .root_source_file = b.path("src/r2.zig"), .imports = &.{.{ .name = "outbound.zig", .module = outbound }} });
    const cli_mod = b.createModule(.{ .root_source_file = b.path("src/cli.zig"), .target = target, .optimize = optimize, .imports = &.{
        .{ .name = "server", .module = server_mod },
        .{ .name = "tilla", .module = tilla },
        .{ .name = "r2", .module = r2 },
        .{ .name = "outbound.zig", .module = outbound },
    } });

    // `audio.encode`: libopus (the float build, no intrinsics) under libopusenc, and libFLAC
    // without Ogg, compiled from their release tarballs. Both encoders link their decoders
    // (libopus's repacketizer, libFLAC's verify mode), which the tests use too.
    const opus_dir = (b.lazyDependency("opus", .{}) orelse return).path("");
    const opusenc_dir = (b.lazyDependency("opusenc", .{}) orelse return).path("");
    const flac_dir = (b.lazyDependency("flac", .{}) orelse return).path("");
    const audio_c = b.addTranslateC(.{ .root_source_file = b.path("src/audio.h"), .target = target, .optimize = optimize });
    // The C code is one static library, compiled once, not once per test root that imports
    // `audio` (~180 files each, which also ran out of file descriptors on the cache).
    const codecs = b.addLibrary(.{ .name = "codecs", .linkage = .static, .root_module = b.createModule(.{ .target = target, .optimize = optimize, .link_libc = true }) });
    const audio = b.createModule(.{ .root_source_file = b.path("src/audio.zig"), .target = target, .optimize = optimize, .link_libc = true });
    for ([_]std.Build.LazyPath{ opus_dir.path(b, "include"), opusenc_dir.path(b, "include"), flac_dir.path(b, "include") }) |dir| {
        audio_c.addIncludePath(dir);
        codecs.root_module.addIncludePath(dir);
    }
    for ([_][]const u8{ "celt", "silk", "silk/float" }) |dir| codecs.root_module.addIncludePath(opus_dir.path(b, dir));
    codecs.root_module.addIncludePath(flac_dir.path(b, "src/libFLAC/include"));
    audio.addImport("c", audio_c.createModule());
    audio.linkLibrary(codecs);
    cli_mod.addImport("audio", audio);
    codecs.root_module.addCSourceFiles(.{
        .root = opus_dir,
        .files = &opus_files,
        .flags = &.{ "-DOPUS_BUILD", "-DVAR_ARRAYS", "-DHAVE_LRINTF", "-DHAVE_LRINT", "-DPACKAGE_VERSION=\"1.6.1\"" },
    });
    codecs.root_module.addCSourceFiles(.{
        .root = opusenc_dir.path(b, "src"),
        .files = &.{ "ogg_packer.c", "opus_header.c", "opusenc.c", "picture.c", "resample.c", "unicode_support.c" },
        .flags = &.{ "-DOUTSIDE_SPEEX", "-DRANDOM_PREFIX=libopusenc", "-DPACKAGE_NAME=\"libopusenc\"", "-DPACKAGE_VERSION=\"0.3\"" },
    });
    codecs.root_module.addCSourceFiles(.{
        .root = flac_dir.path(b, "src/libFLAC"),
        .files = &.{
            "bitmath.c", "bitreader.c", "bitwriter.c",      "cpu.c",            "crc.c",
            "fixed.c",   "float.c",     "format.c",         "lpc.c",            "md5.c",
            "memory.c",  "window.c",    "stream_decoder.c", "stream_encoder.c", "stream_encoder_framing.c",
        },
        .flags = &.{ "-DHAVE_INTTYPES_H", "-DHAVE_LROUND", "-DFLAC__HAS_OGG=0", "-DPACKAGE_VERSION=\"1.5.0\"" },
    });

    const server_exe = b.addExecutable(.{ .name = "postilla-server", .root_module = server_mod });
    const cli_exe = b.addExecutable(.{ .name = "postilla", .root_module = cli_mod });
    b.installArtifact(server_exe);
    b.installArtifact(cli_exe);

    b.step("run", "Run postilla-server (config from env)").dependOn(&b.addRunArtifact(server_exe).step);

    // Every test/*.zig except the harness is a test root. Tests start the real server
    // through the `server` module and talk HTTP to it.
    const harness = b.createModule(.{
        .root_source_file = b.path("test/harness.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "server", .module = server_mod }},
    });
    const test_step = b.step("test", "Run the integration tests");
    // The configure phase is cached: without this, a file added to test/ is ignored
    // until the cache is cleared.
    b.dependOnDirectoryContents(b.path("test"));
    const io = b.graph.io;
    var dir = b.root.root_dir.handle.openDir(io, b.pathJoin(&.{ b.root.sub_path, "test" }), .{ .iterate = true }) catch
        @panic("cannot open test/");
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch @panic("cannot list test/")) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".zig")) continue;
        if (std.mem.eql(u8, entry.name, "harness.zig")) continue;
        const path = b.fmt("test/{s}", .{entry.name});
        if (test_file) |only| if (!std.mem.eql(u8, std.fs.path.basename(only), entry.name)) continue;
        const t = b.addTest(.{ .root_module = b.createModule(.{
            .root_source_file = b.path(path),
            .target = target,
            .optimize = optimize,
            .imports = &.{
                .{ .name = "server", .module = server_mod },
                .{ .name = "harness", .module = harness },
                .{ .name = "words", .module = words },
                .{ .name = "tilla", .module = tilla },
                .{ .name = "r2", .module = r2 },
                .{ .name = "cli", .module = cli_mod },
                .{ .name = "audio", .module = audio },
            },
        }) });
        if (coverage) {
            const run = b.addSystemCommand(&.{ "kcov", "--include-pattern=/src/" });
            run.addArg("coverage/kcov");
            run.addArtifactArg(t);
            test_step.dependOn(&run.step);
        } else {
            test_step.dependOn(&b.addRunArtifact(t).step);
        }
    }

    // The Italian moderation test set calls the real Jev, so it runs only on demand.
    const live = b.addRunArtifact(b.addTest(.{ .root_module = b.createModule(.{
        .root_source_file = b.path("test/live/moderation.zig"),
        .target = target,
        .optimize = optimize,
        .imports = &.{.{ .name = "cli", .module = cli_mod }},
    }) }));
    live.has_side_effects = true;
    b.step("test-moderation", "Send the Italian moderation test set to the real Jev (spends credits)").dependOn(&live.step);
}

fn module(
    b: *std.Build,
    root: []const u8,
    target: std.Build.ResolvedTarget,
    optimize: std.builtin.OptimizeMode,
    c_mod: *std.Build.Module,
    sqlite_dir: std.Build.LazyPath,
) *std.Build.Module {
    const m = b.createModule(.{
        .root_source_file = b.path(root),
        .target = target,
        .optimize = optimize,
        .link_libc = true,
        .imports = &.{.{ .name = "c", .module = c_mod }},
    });
    m.addIncludePath(sqlite_dir);
    m.addCSourceFile(.{
        .file = sqlite_dir.path(b, "sqlite3.c"),
        .flags = &.{
            "-DSQLITE_THREADSAFE=2",
            "-DSQLITE_DQS=0",
            "-DSQLITE_DEFAULT_MEMSTATUS=0",
            "-DSQLITE_OMIT_LOAD_EXTENSION",
            "-DSQLITE_OMIT_DEPRECATED",
            "-DSQLITE_OMIT_SHARED_CACHE",
            "-DSQLITE_LIKE_DOESNT_MATCH_BLOBS",
        },
    });
    return m;
}

const dart_head =
    \\// Generated by `zig build dart` from postilla-backend's src/words.zig (tilla.md,
    \\// Words). Do not edit.
    \\
    \\/// The normalization of every letter in U+00C0–U+024F.
    \\const table = <int, String>{
    \\
;

const dart_tail =
    \\};
    \\
    \\/// Letters to their lowercase base, combining accents dropped, apostrophes to `'`,
    \\/// hyphens to `-`, the rest unchanged.
    \\String normalize(String text) {
    \\  final out = StringBuffer();
    \\  for (final c in text.runes) {
    \\    if (c >= 0x41 && c <= 0x5a) {
    \\      out.writeCharCode(c + 0x20);
    \\    } else if (c == 0x27 || c == 0x2019 || c == 0x2bc) {
    \\      out.write("'");
    \\    } else if (c == 0x2d || c == 0x2010 || c == 0x2011) {
    \\      out.write('-');
    \\    } else if (c < 0x300 || c > 0x36f) {
    \\      out.write(table[c] ?? String.fromCharCode(c));
    \\    }
    \\  }
    \\  return out.toString();
    \\}
    \\
    \\bool _isLetter(int c) => RegExp('^[a-z]').hasMatch(normalize(String.fromCharCode(c)));
    \\
    \\/// The keys to look `word` up by, in order: as written, normalized, then the same two
    \\/// for the part after the last apostrophe between two letters, skipping a key equal
    \\/// to the one before it.
    \\List<String> lookupKeys(String word) {
    \\  final r = word.runes.toList();
    \\  var tail = 0;
    \\  var prev = 0x20;
    \\  for (var i = 0; i + 1 < r.length; i++) {
    \\    if (normalize(String.fromCharCode(r[i])) == "'" && _isLetter(prev) && _isLetter(r[i + 1])) tail = i + 1;
    \\    if (r[i] < 0x300 || r[i] > 0x36f) prev = r[i];
    \\  }
    \\  final rest = String.fromCharCodes(r.sublist(tail));
    \\  final all = [word, normalize(word), if (tail > 0) ...[rest, normalize(rest)]];
    \\  return [for (var i = 0; i < all.length; i++) if (i == 0 || all[i] != all[i - 1]) all[i]];
    \\}
    \\
;

// Upstream's CELT_SOURCES, SILK_SOURCES, SILK_SOURCES_FLOAT, OPUS_SOURCES and
// OPUS_SOURCES_FLOAT (celt_sources.mk, silk_sources.mk, opus_sources.mk).
const opus_files = [_][]const u8{
    "celt/bands.c",                          "celt/celt.c",                             "celt/celt_decoder.c",               "celt/celt_encoder.c",
    "celt/celt_lpc.c",                       "celt/cwrs.c",                             "celt/entcode.c",                    "celt/entdec.c",
    "celt/entenc.c",                         "celt/kiss_fft.c",                         "celt/laplace.c",                    "celt/mathops.c",
    "celt/mdct.c",                           "celt/modes.c",                            "celt/pitch.c",                      "celt/quant_bands.c",
    "celt/rate.c",                           "celt/vq.c",                               "silk/A2NLSF.c",                     "silk/CNG.c",
    "silk/HP_variable_cutoff.c",             "silk/LPC_analysis_filter.c",              "silk/LPC_fit.c",                    "silk/LPC_inv_pred_gain.c",
    "silk/LP_variable_cutoff.c",             "silk/NLSF2A.c",                           "silk/NLSF_VQ.c",                    "silk/NLSF_VQ_weights_laroia.c",
    "silk/NLSF_decode.c",                    "silk/NLSF_del_dec_quant.c",               "silk/NLSF_encode.c",                "silk/NLSF_stabilize.c",
    "silk/NLSF_unpack.c",                    "silk/NSQ.c",                              "silk/NSQ_del_dec.c",                "silk/PLC.c",
    "silk/VAD.c",                            "silk/VQ_WMat_EC.c",                       "silk/ana_filt_bank_1.c",            "silk/biquad_alt.c",
    "silk/bwexpander.c",                     "silk/bwexpander_32.c",                    "silk/check_control_input.c",        "silk/code_signs.c",
    "silk/control_SNR.c",                    "silk/control_audio_bandwidth.c",          "silk/control_codec.c",              "silk/debug.c",
    "silk/dec_API.c",                        "silk/decode_core.c",                      "silk/decode_frame.c",               "silk/decode_indices.c",
    "silk/decode_parameters.c",              "silk/decode_pitch.c",                     "silk/decode_pulses.c",              "silk/decoder_set_fs.c",
    "silk/enc_API.c",                        "silk/encode_indices.c",                   "silk/encode_pulses.c",              "silk/float/LPC_analysis_filter_FLP.c",
    "silk/float/LPC_inv_pred_gain_FLP.c",    "silk/float/LTP_analysis_filter_FLP.c",    "silk/float/LTP_scale_ctrl_FLP.c",   "silk/float/apply_sine_window_FLP.c",
    "silk/float/autocorrelation_FLP.c",      "silk/float/burg_modified_FLP.c",          "silk/float/bwexpander_FLP.c",       "silk/float/corrMatrix_FLP.c",
    "silk/float/encode_frame_FLP.c",         "silk/float/energy_FLP.c",                 "silk/float/find_LPC_FLP.c",         "silk/float/find_LTP_FLP.c",
    "silk/float/find_pitch_lags_FLP.c",      "silk/float/find_pred_coefs_FLP.c",        "silk/float/inner_product_FLP.c",    "silk/float/k2a_FLP.c",
    "silk/float/noise_shape_analysis_FLP.c", "silk/float/pitch_analysis_core_FLP.c",    "silk/float/process_gains_FLP.c",    "silk/float/regularize_correlations_FLP.c",
    "silk/float/residual_energy_FLP.c",      "silk/float/scale_copy_vector_FLP.c",      "silk/float/scale_vector_FLP.c",     "silk/float/schur_FLP.c",
    "silk/float/sort_FLP.c",                 "silk/float/warped_autocorrelation_FLP.c", "silk/float/wrappers_FLP.c",         "silk/gain_quant.c",
    "silk/init_decoder.c",                   "silk/init_encoder.c",                     "silk/inner_prod_aligned.c",         "silk/interpolate.c",
    "silk/lin2log.c",                        "silk/log2lin.c",                          "silk/pitch_est_tables.c",           "silk/process_NLSFs.c",
    "silk/quant_LTP_gains.c",                "silk/resampler.c",                        "silk/resampler_down2.c",            "silk/resampler_down2_3.c",
    "silk/resampler_private_AR2.c",          "silk/resampler_private_IIR_FIR.c",        "silk/resampler_private_down_FIR.c", "silk/resampler_private_up2_HQ.c",
    "silk/resampler_rom.c",                  "silk/shell_coder.c",                      "silk/sigm_Q15.c",                   "silk/sort.c",
    "silk/stereo_LR_to_MS.c",                "silk/stereo_MS_to_LR.c",                  "silk/stereo_decode_pred.c",         "silk/stereo_encode_pred.c",
    "silk/stereo_find_predictor.c",          "silk/stereo_quant_pred.c",                "silk/sum_sqr_shift.c",              "silk/table_LSF_cos.c",
    "silk/tables_LTP.c",                     "silk/tables_NLSF_CB_NB_MB.c",             "silk/tables_NLSF_CB_WB.c",          "silk/tables_gain.c",
    "silk/tables_other.c",                   "silk/tables_pitch_lag.c",                 "silk/tables_pulses_per_block.c",    "src/analysis.c",
    "src/extensions.c",                      "src/mapping_matrix.c",                    "src/mlp.c",                         "src/mlp_data.c",
    "src/opus.c",                            "src/opus_decoder.c",                      "src/opus_encoder.c",                "src/opus_multistream.c",
    "src/opus_multistream_decoder.c",        "src/opus_multistream_encoder.c",          "src/opus_projection_decoder.c",     "src/opus_projection_encoder.c",
    "src/repacketizer.c",
};
