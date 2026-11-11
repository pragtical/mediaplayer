/* SPDX-License-Identifier: MIT */
#include <math.h>
#include <stdbool.h>
#include <stdatomic.h>
#include <stdint.h>
#include <string.h>

#include "audio/pragtical_samples.h"
#include "audio/format.h"
#include "audio/out/internal.h"
#include "common/global.h"
#include "player/client.h"
#include "ta/ta_talloc.h"

enum { CAPACITY = 2048, CHANNELS = 2 };

struct pragtical_audio_samples {
    atomic_bool enabled;
    atomic_flag busy;
    float samples[CAPACITY * CHANNELS];
    int write, frames, channels, sample_rate;
    uint64_t sequence;
};

void pragtical_audio_samples_init(struct mpv_global *global)
{
    struct pragtical_audio_samples *state =
        talloc_zero(global, struct pragtical_audio_samples);
    atomic_init(&state->enabled, false);
    atomic_flag_clear(&state->busy);
    global->pragtical_audio = state;
}

/* Samples use mpv's native-endian PCM formats. memcpy permits unaligned
 * device buffers and compiles to ordinary loads for these constant sizes. */
static float read_sample(const unsigned char *data, int format)
{
    switch (format) {
    case AF_FORMAT_U8:
        return ((int)*data - 128) / 128.0f;
    case AF_FORMAT_S16: {
        int16_t value;
        memcpy(&value, data, sizeof(value));
        return value / 32768.0f;
    }
    case AF_FORMAT_S32: {
        int32_t value;
        memcpy(&value, data, sizeof(value));
        return (float)(value / 2147483648.0);
    }
    case AF_FORMAT_S64: {
        int64_t value;
        memcpy(&value, data, sizeof(value));
        return (float)(value / 9223372036854775808.0);
    }
    case AF_FORMAT_FLOAT: {
        float value;
        memcpy(&value, data, sizeof(value));
        return isfinite(value) ? value : 0;
    }
    case AF_FORMAT_DOUBLE: {
        double value;
        memcpy(&value, data, sizeof(value));
        return isfinite(value) && fabs(value) <= 1 ? (float)value
            : value > 1 ? 1 : value < -1 ? -1 : 0;
    }
    default:
        return 0;
    }
}

void pragtical_audio_samples_push(struct ao *ao, void **data, int frames)
{
    struct pragtical_audio_samples *state = ao->global->pragtical_audio;
    if (!state || !frames || !data ||
        !atomic_load_explicit(&state->enabled, memory_order_relaxed))
        return;
    /* Audio never waits for analysis. A competing reader only loses a sample
     * window; it cannot delay the device callback or cause an underrun. */
    if (atomic_flag_test_and_set_explicit(&state->busy, memory_order_acquire))
        return;
    if (!atomic_load_explicit(&state->enabled, memory_order_relaxed))
        goto done;
    if (!af_fmt_is_pcm(ao->format) || ao->channels.num < 1) {
        state->frames = 0;
        goto done;
    }
    int channels = ao->channels.num < CHANNELS ? ao->channels.num : CHANNELS;
    if (channels != state->channels || ao->samplerate != state->sample_rate) {
        state->write = state->frames = 0;
        state->channels = channels;
        state->sample_rate = ao->samplerate;
    }
    int bytes = af_fmt_to_bytes(ao->format);
    int format = af_fmt_from_planar(ao->format);
    bool planar = af_fmt_is_planar(ao->format);
    int first = frames > CAPACITY ? frames - CAPACITY : 0;
    for (int frame = first; frame < frames; frame++) {
        for (int channel = 0; channel < channels; channel++) {
            const unsigned char *plane = data[planar ? channel : 0];
            size_t sample = planar ? frame : frame * ao->channels.num + channel;
            state->samples[state->write * channels + channel] =
                read_sample(plane + sample * bytes, format);
        }
        state->write = (state->write + 1) % CAPACITY;
        if (state->frames < CAPACITY) state->frames++;
    }
    state->sequence++;
done:
    atomic_flag_clear_explicit(&state->busy, memory_order_release);
}

int mpv_pragtical_audio_capture(mpv_handle *client, int enabled)
{
    if (!client || (enabled != 0 && enabled != 1))
        return MPV_ERROR_INVALID_PARAMETER;
    struct pragtical_audio_samples *state =
        mp_client_get_global(client)->pragtical_audio;
    if (!state)
        return MPV_ERROR_UNINITIALIZED;
    if (atomic_flag_test_and_set_explicit(&state->busy, memory_order_acquire))
        return 0;
    state->frames = state->write = 0;
    state->sequence++;
    atomic_store_explicit(&state->enabled, enabled != 0, memory_order_relaxed);
    atomic_flag_clear_explicit(&state->busy, memory_order_release);
    return 1;
}

int mpv_pragtical_audio_samples(mpv_handle *client, float *samples, int capacity,
    int *channels, int *sample_rate, uint64_t *sequence)
{
    if (!client || !samples || !channels || !sample_rate || !sequence ||
        capacity < 1 || capacity > CAPACITY)
        return MPV_ERROR_INVALID_PARAMETER;
    struct pragtical_audio_samples *state =
        mp_client_get_global(client)->pragtical_audio;
    if (!state)
        return MPV_ERROR_UNINITIALIZED;
    if (atomic_flag_test_and_set_explicit(&state->busy, memory_order_acquire))
        return 0;
    int frames = 0;
    if (atomic_load_explicit(&state->enabled, memory_order_relaxed) &&
        state->sequence != *sequence && state->frames) {
        frames = state->frames < capacity ? state->frames : capacity;
        int start = (state->write + CAPACITY - frames) % CAPACITY;
        int first = frames < CAPACITY - start ? frames : CAPACITY - start;
        size_t stride = state->channels * sizeof(float);
        memcpy(samples, state->samples + start * state->channels, first * stride);
        memcpy((char *)samples + first * stride, state->samples, (frames - first) * stride);
        *channels = state->channels;
        *sample_rate = state->sample_rate;
        *sequence = state->sequence;
    }
    atomic_flag_clear_explicit(&state->busy, memory_order_release);
    return frames;
}
