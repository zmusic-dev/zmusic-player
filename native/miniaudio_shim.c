#include "miniaudio_shim.h"

#include <stdlib.h>

#include "miniaudio.h"

struct zm_engine {
    ma_engine value;
    ma_context fallback_context;
    ma_bool32 has_fallback_context;
};

struct zm_sound {
    ma_sound value;
    ma_decoder decoder;
    ma_bool32 has_decoder;
    zm_stream_read_proc read_proc;
    zm_stream_seek_proc seek_proc;
    void *user_data;
};

static ma_result zm_decoder_read(
    ma_decoder *decoder,
    void *buffer_out,
    size_t bytes_to_read,
    size_t *bytes_read
) {
    zm_sound *sound = (zm_sound *)decoder->pUserData;
    int32_t result;

    if (sound == NULL || sound->read_proc == NULL) {
        return MA_INVALID_ARGS;
    }

    result = sound->read_proc(
        sound->user_data,
        buffer_out,
        bytes_to_read,
        bytes_read
    );

    if (result == 0) return MA_SUCCESS;
    if (result == 1) return MA_AT_END;
    return MA_ERROR;
}

static ma_result zm_decoder_seek(
    ma_decoder *decoder,
    ma_int64 byte_offset,
    ma_seek_origin origin
) {
    zm_sound *sound = (zm_sound *)decoder->pUserData;
    int32_t result;

    if (sound == NULL || sound->seek_proc == NULL) {
        return MA_INVALID_ARGS;
    }

    result = sound->seek_proc(
        sound->user_data,
        (int64_t)byte_offset,
        (int32_t)origin
    );
    return result == 0 ? MA_SUCCESS : MA_INVALID_ARGS;
}

zm_engine *zm_engine_create(void) {
    zm_engine *engine = (zm_engine *)calloc(1, sizeof(*engine));
    ma_engine_config config;
    ma_backend fallback_backend = ma_backend_null;

    if (engine == NULL) return NULL;

    config = ma_engine_config_init();
    if (ma_engine_init(&config, &engine->value) != MA_SUCCESS) {
        if (ma_context_init(
                &fallback_backend,
                1,
                NULL,
                &engine->fallback_context
            ) != MA_SUCCESS) {
            free(engine);
            return NULL;
        }
        engine->has_fallback_context = MA_TRUE;
        config = ma_engine_config_init();
        config.pContext = &engine->fallback_context;
        if (ma_engine_init(&config, &engine->value) != MA_SUCCESS) {
            ma_context_uninit(&engine->fallback_context);
            free(engine);
            return NULL;
        }
    }
    return engine;
}

void zm_engine_destroy(zm_engine *engine) {
    if (engine == NULL) return;
    ma_engine_uninit(&engine->value);
    if (engine->has_fallback_context) {
        ma_context_uninit(&engine->fallback_context);
    }
    free(engine);
}

int32_t zm_engine_set_volume(zm_engine *engine, float volume) {
    if (engine == NULL) return -1;
    return ma_engine_set_volume(&engine->value, volume) == MA_SUCCESS ? 0 : -1;
}

zm_sound *zm_sound_create_file(zm_engine *engine, const char *path) {
    zm_sound *sound;

    if (engine == NULL || path == NULL) return NULL;
    sound = (zm_sound *)calloc(1, sizeof(*sound));
    if (sound == NULL) return NULL;

    if (ma_sound_init_from_file(
            &engine->value,
            path,
            MA_SOUND_FLAG_DECODE,
            NULL,
            NULL,
            &sound->value
        ) != MA_SUCCESS) {
        free(sound);
        return NULL;
    }
    return sound;
}

zm_sound *zm_sound_create_stream(
    zm_engine *engine,
    zm_stream_read_proc read_proc,
    zm_stream_seek_proc seek_proc,
    void *user_data
) {
    zm_sound *sound;

    if (engine == NULL || read_proc == NULL || seek_proc == NULL) return NULL;
    sound = (zm_sound *)calloc(1, sizeof(*sound));
    if (sound == NULL) return NULL;

    sound->read_proc = read_proc;
    sound->seek_proc = seek_proc;
    sound->user_data = user_data;

    if (ma_decoder_init(
            zm_decoder_read,
            zm_decoder_seek,
            sound,
            NULL,
            &sound->decoder
        ) != MA_SUCCESS) {
        free(sound);
        return NULL;
    }
    sound->has_decoder = MA_TRUE;

    if (ma_sound_init_from_data_source(
            &engine->value,
            (ma_data_source *)&sound->decoder,
            MA_SOUND_FLAG_NO_PITCH | MA_SOUND_FLAG_NO_SPATIALIZATION,
            NULL,
            &sound->value
        ) != MA_SUCCESS) {
        ma_decoder_uninit(&sound->decoder);
        free(sound);
        return NULL;
    }

    return sound;
}

void zm_sound_destroy(zm_sound *sound) {
    if (sound == NULL) return;
    ma_sound_stop(&sound->value);
    ma_sound_uninit(&sound->value);
    if (sound->has_decoder) {
        ma_decoder_uninit(&sound->decoder);
    }
    free(sound);
}

int32_t zm_sound_start(zm_sound *sound) {
    if (sound == NULL) return -1;
    return ma_sound_start(&sound->value) == MA_SUCCESS ? 0 : -1;
}

int32_t zm_sound_stop(zm_sound *sound) {
    if (sound == NULL) return -1;
    return ma_sound_stop(&sound->value) == MA_SUCCESS ? 0 : -1;
}

int32_t zm_sound_set_volume(zm_sound *sound, float volume) {
    if (sound == NULL) return -1;
    ma_sound_set_volume(&sound->value, volume);
    return 0;
}

int32_t zm_sound_seek_ms(zm_sound *sound, uint64_t position_ms) {
    ma_uint32 sample_rate = 0;
    ma_uint64 target_frame;

    if (sound == NULL) return -1;
    if (ma_sound_get_data_format(
            &sound->value,
            NULL,
            NULL,
            &sample_rate,
            NULL,
            0
        ) != MA_SUCCESS || sample_rate == 0) {
        return -1;
    }

    target_frame = (position_ms / 1000) * sample_rate;
    target_frame += ((position_ms % 1000) * sample_rate) / 1000;
    return ma_sound_seek_to_pcm_frame(&sound->value, target_frame) == MA_SUCCESS ? 0 : -1;
}

uint64_t zm_sound_position_ms(const zm_sound *sound) {
    ma_uint32 sample_rate = 0;
    ma_uint64 cursor = 0;

    if (sound == NULL) return 0;
    if (ma_sound_get_data_format(
            &sound->value,
            NULL,
            NULL,
            &sample_rate,
            NULL,
            0
        ) != MA_SUCCESS || sample_rate == 0) {
        return 0;
    }
    if (ma_sound_get_cursor_in_pcm_frames(&sound->value, &cursor) != MA_SUCCESS) {
        return 0;
    }
    return (cursor / sample_rate) * 1000 + ((cursor % sample_rate) * 1000) / sample_rate;
}

uint64_t zm_sound_duration_ms(const zm_sound *sound) {
    ma_uint32 sample_rate = 0;
    ma_uint64 length = 0;

    if (sound == NULL) return 0;
    if (ma_sound_get_data_format(
            &sound->value,
            NULL,
            NULL,
            &sample_rate,
            NULL,
            0
        ) != MA_SUCCESS || sample_rate == 0) {
        return 0;
    }
    if (ma_sound_get_length_in_pcm_frames(&sound->value, &length) != MA_SUCCESS) {
        return 0;
    }
    return (length / sample_rate) * 1000 + ((length % sample_rate) * 1000) / sample_rate;
}

int32_t zm_sound_at_end(const zm_sound *sound) {
    if (sound == NULL) return 0;
    return ma_sound_at_end(&sound->value) ? 1 : 0;
}
