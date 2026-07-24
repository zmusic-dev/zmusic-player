#ifndef ZMUSIC_MINIAUDIO_SHIM_H
#define ZMUSIC_MINIAUDIO_SHIM_H

#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif
typedef struct zm_engine zm_engine;
typedef struct zm_sound zm_sound;

typedef int32_t (*zm_stream_read_proc)(
    void *user_data,
    void *buffer_out,
    size_t bytes_to_read,
    size_t *bytes_read
);

typedef int32_t (*zm_stream_seek_proc)(
    void *user_data,
    int64_t byte_offset,
    int32_t origin
);

zm_engine *zm_engine_create(void);
void zm_engine_destroy(zm_engine *engine);
int32_t zm_engine_set_volume(zm_engine *engine, float volume);

zm_sound *zm_sound_create_file(zm_engine *engine, const char *path);
zm_sound *zm_sound_create_stream(
    zm_engine *engine,
    zm_stream_read_proc read_proc,
    zm_stream_seek_proc seek_proc,
    void *user_data
);
void zm_sound_destroy(zm_sound *sound);
int32_t zm_sound_start(zm_sound *sound);
int32_t zm_sound_stop(zm_sound *sound);
int32_t zm_sound_set_volume(zm_sound *sound, float volume);
int32_t zm_sound_seek_ms(zm_sound *sound, uint64_t position_ms);
uint64_t zm_sound_position_ms(const zm_sound *sound);
uint64_t zm_sound_duration_ms(const zm_sound *sound);
int32_t zm_sound_at_end(const zm_sound *sound);

#ifdef __cplusplus
}
#endif

#endif
