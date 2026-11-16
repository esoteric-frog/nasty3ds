#pragma once
#include <stdbool.h>
#include <stddef.h>
#include <stdint.h>

typedef struct { const char *key; const char *value; } n3_option;

/* pixels are XRGB8888 (in memory: B, G, R, X). Called on the emulation thread. */
typedef void (*n3_video_fn)(const void *pixels, unsigned width, unsigned height, size_t pitch);
/* interleaved stereo Int16; frames = sample pairs. Returns frames taken. */
typedef size_t (*n3_audio_fn)(const int16_t *samples, size_t frames);
typedef int16_t (*n3_input_fn)(unsigned port, unsigned device, unsigned index, unsigned id);
typedef void (*n3_log_fn)(int level, const char *line);

typedef struct {
    const char *save_dir;      /* all strings must stay valid until n3_unload */
    const char *system_dir;
    const n3_option *options;
    size_t option_count;
    n3_video_fn video;
    n3_audio_fn audio;
    n3_input_fn input;
    n3_log_fn log;
} n3_config;

/* 0 = ok. On failure, err holds a message. */
int  n3_load_core(const char *dylib_path, const n3_config *config, char *err, size_t err_len);
int  n3_load_game(const char *game_path, char *err, size_t err_len);
void n3_av_info(unsigned *width, unsigned *height, double *fps, double *sample_rate);
void n3_run(void);      /* one frame; emulation thread only */
void n3_unload(void);

/* Local play (the 3DS "local wireless", for example a trade). One player hosts a room, the
   others join it. Every function returns -1 when the loaded core has no room support.
   host/join: 0 = ok, 1 = network failed, 2 = no game runs, 3 = the port is in use.
   state: 0 = not in a room, 1 = joining, 2 = joined, below 0 = the last join failed. */
int n3_room_host(const char *nickname, unsigned short port, unsigned max_players);
int n3_room_join(const char *nickname, const char *address, unsigned short port);
void n3_room_leave(void);
int n3_room_state(void);
int n3_room_members(char *out, unsigned long length); /* names, one per line; returns the count */
