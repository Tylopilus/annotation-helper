//! Builds annotation-helper, including whisper.cpp from source.
//! Compile flags mirror whisper.cpp's CMake build (v1.8.3, CPU backend, AVX2 baseline).
//!
//!   zig build --release=safe                                  Windows tray app (default target)
//!   zig build --release=safe -Dtarget=x86_64-linux-gnu        Linux tray app (X11 + Wayland)
//!
//! ReleaseSafe keeps bounds and overflow checks in the app; whisper.cpp is always ReleaseFast.

const std = @import("std");

pub fn build(b: *std.Build) void {
    const target = b.standardTargetOptions(.{ .default_target = .{
        .cpu_arch = .x86_64,
        .os_tag = .windows,
        .abi = .gnu,
        // AVX2/FMA/F16C/BMI2: what ggml is compiled for (any CPU since ~2013).
        .cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 },
    } });
    const optimize = b.standardOptimizeOption(.{ .preferred_optimize_mode = .ReleaseSafe });

    const whisper = buildWhisper(b, target);
    // Zig 0.17 keeps GitHub archives' top-level folder (it treats them as manifest-less
    // packages), so the packages are addressed through that folder.
    const win32 = b.createModule(.{
        .root_source_file = b.dependency("win32", .{}).path(win32_root ++ "win32.zig"),
    });

    const is_windows = target.result.os.tag == .windows;
    if (target.result.cpu.arch != .x86_64) @panic("only x86_64 targets are supported (ggml is built for AVX2)");

    const exe = b.addExecutable(.{
        .name = "annotation-helper",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            // Linux release builds: drop the ~20 MB of debug info (Windows keeps it in a .pdb).
            .strip = if (!is_windows and optimize != .debug) true else null,
            .imports = &.{.{ .name = "win32", .module = win32 }},
        }),
    });
    exe.root_module.linkLibrary(whisper);
    if (is_windows) exe.subsystem = .windows else linkLinux(exe);
    b.installArtifact(exe);

    // Unit tests: `zig build test-exe`, then run zig-out/bin/tests(.exe) on the target OS.
    const tests = b.addTest(.{
        .name = "tests",
        .root_module = b.createModule(.{
            .root_source_file = b.path("src/main.zig"),
            .target = target,
            .optimize = optimize,
            .link_libc = true,
            .imports = &.{.{ .name = "win32", .module = win32 }},
        }),
    });
    tests.root_module.linkLibrary(whisper);
    if (!is_windows) linkLinux(tests);
    b.step("test-exe", "Build the unit tests").dependOn(&b.addInstallArtifact(tests, .{}).step);
}

/// miniaudio and xkbcommon are loaded at runtime (dlopen), so only libc's own parts.
fn linkLinux(c: *std.Build.Step.Compile) void {
    c.root_module.linkSystemLibrary("dl", .{});
    c.root_module.linkSystemLibrary("pthread", .{});
    c.root_module.linkSystemLibrary("m", .{});
}

const win32_root = "zigwin32-fb2645891520f3e99931db17a7eba04057e87e89/";
const whisper_root = "whisper.cpp-1.8.3/";
/// Unlike the two archives above, Zig 0.17 strips stb's top-level folder.
const stb_root = "";

fn buildWhisper(b: *std.Build, target: std.Build.ResolvedTarget) *std.Build.Step.Compile {
    const src = b.dependency("whisper_cpp", .{});
    // ggml picks its SIMD code paths from the compiler's target CPU (__AVX2__ etc.).
    // `-mavx2` alone is overridden by Zig's `-mcpu baseline` (e.g. for -Dtarget=x86_64-linux-gnu),
    // which silently selects the scalar fallback: 12x slower transcription.
    var q = target.query;
    q.cpu_model = .{ .explicit = &std.Target.x86.cpu.x86_64_v3 };
    const lib = b.addLibrary(.{
        .name = "whisper",
        .linkage = .static,
        .root_module = b.createModule(.{
            .target = b.resolveTargetQuery(q),
            // whisper is unusably slow without optimizations, even in debug builds.
            .optimize = .ReleaseFast,
            .link_libc = true,
            .link_libcpp = true,
        }),
    });
    const m = lib.root_module;
    for ([_][]const u8{ "include", "src", "ggml/include", "ggml/src", "ggml/src/ggml-cpu" }) |dir| {
        m.addIncludePath(src.path(b.fmt(whisper_root ++ "{s}", .{dir})));
    }
    const is_windows = target.result.os.tag == .windows;
    const common = [_][]const u8{
        // Linux: CPU affinity and memory helpers need GNU extensions (as in ggml's CMake).
        if (is_windows) "-D_CRT_SECURE_NO_WARNINGS" else "-D_GNU_SOURCE",
        "-w",
        "-DNDEBUG",
        "-D_XOPEN_SOURCE=600",
        "-DGGML_SCHED_MAX_COPIES=4",
        "-DGGML_USE_CPU",
        "-DGGML_USE_CPU_REPACK",
        "-DGGML_AVX",
        "-DGGML_AVX2",
        "-DGGML_BMI2",
        "-DGGML_F16C",
        "-DGGML_FMA",
        "-DGGML_VERSION=\"0.9.5\"",
        "-DGGML_COMMIT=\"unknown\"",
        "-DWHISPER_VERSION=\"1.8.3\"",
        "-D_DISABLE_CONSTEXPR_MUTEX_CONSTRUCTOR",
    };
    m.addCSourceFiles(.{
        .root = src.path(whisper_root),
        .files = &.{
            "ggml/src/ggml.c",
            "ggml/src/ggml-alloc.c",
            "ggml/src/ggml-quants.c",
            "ggml/src/ggml-cpu/ggml-cpu.c",
            "ggml/src/ggml-cpu/quants.c",
            "ggml/src/ggml-cpu/arch/x86/quants.c",
        },
        .flags = &(common ++ [_][]const u8{"-std=gnu11"}),
    });
    m.addCSourceFiles(.{
        .root = src.path(whisper_root),
        .files = &.{
            "ggml/src/ggml.cpp",
            "ggml/src/ggml-backend.cpp",
            "ggml/src/ggml-backend-reg.cpp",
            "ggml/src/ggml-opt.cpp",
            "ggml/src/ggml-threading.cpp",
            "ggml/src/gguf.cpp",
            "ggml/src/ggml-cpu/ggml-cpu.cpp",
            "ggml/src/ggml-cpu/repack.cpp",
            "ggml/src/ggml-cpu/ops.cpp",
            "ggml/src/ggml-cpu/binary-ops.cpp",
            "ggml/src/ggml-cpu/unary-ops.cpp",
            "ggml/src/ggml-cpu/vec.cpp",
            "ggml/src/ggml-cpu/traits.cpp",
            "ggml/src/ggml-cpu/hbm.cpp",
            "ggml/src/ggml-cpu/amx/amx.cpp",
            "ggml/src/ggml-cpu/amx/mmq.cpp",
            "ggml/src/ggml-cpu/arch/x86/repack.cpp",
            "src/whisper.cpp",
        },
        .flags = &(common ++ [_][]const u8{"-std=gnu++17"}),
    });
    m.addCSourceFile(.{ .file = b.path("csrc/whisper_shim.c"), .flags = &.{ "-std=c11", "-w" } });
    // miniaudio ships with whisper.cpp (examples/miniaudio.h).
    m.addIncludePath(src.path(whisper_root ++ "examples"));
    m.addCSourceFile(.{ .file = b.path("csrc/audio_shim.c"), .flags = &.{ "-std=gnu11", "-w", "-DNDEBUG" } });
    if (!is_windows) {
        // PNGs and banner text (WIC and GDI do this on Windows). stb_image_resize2 moved
        // to its own repo; the pinned commit still has it under deprecated/.
        const stb = b.dependency("stb", .{});
        m.addIncludePath(stb.path(stb_root));
        m.addIncludePath(stb.path(stb_root ++ "deprecated"));
        m.addCSourceFile(.{ .file = b.path("csrc/image_shim.c"), .flags = &.{ "-std=gnu11", "-w", "-DNDEBUG" } });
        m.addCSourceFile(.{ .file = b.path("csrc/text_shim.c"), .flags = &.{ "-std=gnu11", "-w", "-DNDEBUG" } });
    }
    return lib;
}
