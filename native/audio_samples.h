/* SPDX-License-Identifier: MIT */
#ifndef PRAGTICAL_MPV_AUDIO_SAMPLES_H
#define PRAGTICAL_MPV_AUDIO_SAMPLES_H

#include <stdint.h>
#include "mpv/client.h"

struct mpv_global;
struct ao;

/* Initialize once before the client's audio threads start. */
void pragtical_audio_samples_init(struct mpv_global *global);

/* Called only by native audio output code; never calls into Lua. */
void pragtical_audio_samples_push(struct ao *ao, void **data, int frames);

/* Enable/disable a 2048-frame stereo PCM window. Returns 1 on success,
 * 0 if capture is busy (retry later), or MPV_ERROR_INVALID_PARAMETER.
 * Enabling or disabling resets previous samples. This never waits for the
 * playback core or an audio callback. Call from the owning client thread. */
MPV_EXPORT int mpv_pragtical_audio_capture(mpv_handle *client, int enabled);

/* Copy the latest interleaved floats, in chronological order. Returns a
 * frame count, 0 if busy/unchanged/empty, or MPV_ERROR_INVALID_PARAMETER.
 * capacity is measured in frames, with space for two channels per frame.
 * sequence is an input/output change counter owned by this reader. */
MPV_EXPORT int mpv_pragtical_audio_samples(mpv_handle *client, float *samples,
    int capacity, int *channels, int *sample_rate, uint64_t *sequence);

#endif
