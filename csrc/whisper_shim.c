// Thin C layer over whisper.h so the Zig side never has to mirror
// `struct whisper_full_params` (large, version-dependent) field by field.
#include <stdint.h>
#include <string.h>
#include "whisper.h"

typedef void (*ah_segment_cb)(void *user, int64_t t0_cs, int64_t t1_cs, const char *text);

static void ah_quiet(enum ggml_log_level level, const char *text, void *user) {
    (void)level; (void)text; (void)user;
}

// Returns 0 on success; writes the detected language code into lang_out.
int ah_transcribe(const char *model_path, const float *pcm, int n_samples, const char *language,
                  int n_threads, ah_segment_cb cb, void *user, char *lang_out, int lang_out_len) {
    whisper_log_set(ah_quiet, NULL);
    struct whisper_context_params cparams = whisper_context_default_params();
    struct whisper_context *ctx = whisper_init_from_file_with_params(model_path, cparams);
    if (!ctx) return 1;

    struct whisper_full_params p = whisper_full_default_params(WHISPER_SAMPLING_BEAM_SEARCH);
    p.beam_search.beam_size = 5;
    p.n_threads = n_threads;
    p.language = (language && language[0]) ? language : "auto";
    p.print_progress = false;
    p.print_realtime = false;
    p.print_special = false;
    p.print_timestamps = false;
    p.suppress_nst = true;

    if (whisper_full(ctx, p, pcm, n_samples) != 0) {
        whisper_free(ctx);
        return 2;
    }
    const char *lang = whisper_lang_str(whisper_full_lang_id(ctx));
    if (lang && lang_out && lang_out_len > 0) {
        strncpy(lang_out, lang, (size_t)lang_out_len - 1);
        lang_out[lang_out_len - 1] = 0;
    }
    int n = whisper_full_n_segments(ctx);
    for (int i = 0; i < n; i++) {
        cb(user, whisper_full_get_segment_t0(ctx, i), whisper_full_get_segment_t1(ctx, i),
           whisper_full_get_segment_text(ctx, i));
    }
    whisper_free(ctx);
    return 0;
}
