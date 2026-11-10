// Microphone capture and WAV decoding via miniaudio (bundled with whisper.cpp).
// miniaudio converts and resamples, so we record straight to 16 kHz mono 16-bit,
// which is what whisper wants. Windows: WASAPI only. Linux build: decoding only
// (MA_NO_DEVICE_IO is set by build.zig), as it never records.
#define MINIAUDIO_IMPLEMENTATION
#define MA_ENABLE_ONLY_SPECIFIC_BACKENDS
#define MA_ENABLE_WASAPI
#define MA_NO_GENERATION
#define MA_NO_ENGINE
#define MA_NO_NODE_GRAPH
#define MA_NO_RESOURCE_MANAGER
#define MA_NO_MP3
#define MA_NO_FLAC
#include <stdint.h>
#include <string.h>
#include "miniaudio.h"

#ifndef MA_NO_DEVICE_IO
#include <windows.h>

static ma_device g_dev;
static ma_encoder g_enc;
static int g_running;
static volatile int64_t g_first_ms; // monotonic ms of the first sample (0 = none yet)
static char g_name[256];
static const char *g_error = "";

// Same clock as util.nowMs() on the Zig side.
static int64_t now_ms(void) {
    LARGE_INTEGER f, c;
    QueryPerformanceFrequency(&f);
    QueryPerformanceCounter(&c);
    return (int64_t)((c.QuadPart * 1000) / f.QuadPart);
}

static void on_capture(ma_device *dev, void *out, const void *in, ma_uint32 frames) {
    (void)out;
    if (g_first_ms == 0) g_first_ms = now_ms() - (int64_t)frames * 1000 / dev->sampleRate;
    ma_encoder_write_pcm_frames(&g_enc, in, frames, NULL);
}

static ma_device_config capture_config(ma_device_data_proc cb, ma_uint32 rate) {
    ma_device_config cfg = ma_device_config_init(ma_device_type_capture);
    cfg.capture.format = ma_format_s16;
    cfg.capture.channels = 1;
    cfg.sampleRate = rate;
    cfg.dataCallback = cb;
    return cfg;
}

// Starts recording the default microphone into `path`. Returns 0 on success.
int ah_audio_start(const wchar_t *path, uint32_t rate) {
    if (g_running) return 1;
    g_first_ms = 0;
    ma_encoder_config ecfg = ma_encoder_config_init(ma_encoding_format_wav, ma_format_s16, 1, rate);
    ma_result r = ma_encoder_init_file_w(path, &ecfg, &g_enc);
    if (r != MA_SUCCESS) { g_error = ma_result_description(r); return 2; }
    ma_device_config cfg = capture_config(on_capture, rate);
    r = ma_device_init(NULL, &cfg, &g_dev);
    if (r != MA_SUCCESS) { g_error = ma_result_description(r); ma_encoder_uninit(&g_enc); return 3; }
    ma_device_get_name(&g_dev, ma_device_type_capture, g_name, sizeof g_name, NULL);
    r = ma_device_start(&g_dev);
    if (r != MA_SUCCESS) { g_error = ma_result_description(r); ma_device_uninit(&g_dev); ma_encoder_uninit(&g_enc); return 4; }
    g_running = 1;
    return 0;
}

// Stops recording and finalizes the WAV header. Returns the first sample's time (ms).
int64_t ah_audio_stop(void) {
    if (!g_running) return 0;
    ma_device_uninit(&g_dev); // stops and waits for the callback to finish
    ma_encoder_uninit(&g_enc);
    g_running = 0;
    return g_first_ms;
}

const char *ah_audio_device_name(void) { return g_name; }
const char *ah_audio_error(void) { return g_error; }

// ---- probe: open the microphone briefly, count frames and the peak level, write nothing.

static volatile uint64_t g_probe_frames;
static volatile int g_probe_peak;

static void on_probe(ma_device *dev, void *out, const void *in, ma_uint32 frames) {
    (void)dev; (void)out;
    const int16_t *s = (const int16_t *)in;
    int peak = g_probe_peak;
    for (ma_uint32 i = 0; i < frames; i++) {
        int v = s[i] < 0 ? -s[i] : s[i];
        if (v > peak) peak = v;
    }
    g_probe_peak = peak;
    g_probe_frames += frames;
}

// Returns 0 on success; frames received and peak (0..32768) via out params.
int ah_audio_probe(uint32_t ms, uint64_t *frames, int *peak, char *name, int name_len) {
    ma_device dev;
    g_probe_frames = 0;
    g_probe_peak = 0;
    ma_device_config cfg = capture_config(on_probe, 16000);
    ma_result r = ma_device_init(NULL, &cfg, &dev);
    if (r != MA_SUCCESS) { g_error = ma_result_description(r); return 1; }
    ma_device_get_name(&dev, ma_device_type_capture, name, (size_t)name_len, NULL);
    r = ma_device_start(&dev);
    if (r != MA_SUCCESS) { g_error = ma_result_description(r); ma_device_uninit(&dev); return 2; }
    Sleep(ms);
    ma_device_uninit(&dev);
    *frames = g_probe_frames;
    *peak = g_probe_peak;
    return 0;
}

#endif // MA_NO_DEVICE_IO

static const char *g_decode_error = "";
const char *ah_decode_error(void) { return g_decode_error; }

static int decode_all(ma_decoder *dec, float **pcm, uint64_t *frames);

// Decodes any WAV to mono float at `rate`. Caller frees with ah_free. Returns 0 on success.
#ifdef _WIN32
int ah_decode_wav(const wchar_t *path, uint32_t rate, float **pcm, uint64_t *frames) {
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 1, rate);
    ma_decoder dec;
    ma_result r = ma_decoder_init_file_w(path, &cfg, &dec);
    if (r != MA_SUCCESS) { g_decode_error = ma_result_description(r); return 1; }
    return decode_all(&dec, pcm, frames);
}
#else
int ah_decode_wav_utf8(const char *path, uint32_t rate, float **pcm, uint64_t *frames) {
    ma_decoder_config cfg = ma_decoder_config_init(ma_format_f32, 1, rate);
    ma_decoder dec;
    ma_result r = ma_decoder_init_file(path, &cfg, &dec);
    if (r != MA_SUCCESS) { g_decode_error = ma_result_description(r); return 1; }
    return decode_all(&dec, pcm, frames);
}
#endif

static int decode_all(ma_decoder *dec, float **pcm, uint64_t *frames) {
    ma_result r;
    ma_uint64 cap = 16000 * 60, n = 0;
    float *buf = (float *)ma_malloc(cap * sizeof(float), NULL);
    for (;;) {
        if (n == cap) {
            cap *= 2;
            float *nb = (float *)ma_realloc(buf, cap * sizeof(float), NULL);
            if (!nb) { ma_free(buf, NULL); ma_decoder_uninit(dec); return 2; }
            buf = nb;
        }
        ma_uint64 got = 0;
        r = ma_decoder_read_pcm_frames(dec, buf + n, cap - n, &got);
        n += got;
        if (r != MA_SUCCESS || got == 0) break;
    }
    ma_decoder_uninit(dec);
    *pcm = buf;
    *frames = n;
    return 0;
}

void ah_free(void *p) { ma_free(p, NULL); }
