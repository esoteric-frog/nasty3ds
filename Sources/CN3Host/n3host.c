#include "n3host.h"
#include "libretro.h"
#include <dlfcn.h>
#include <stdarg.h>
#include <stdio.h>
#include <string.h>

bool n3vk_environment(unsigned cmd, void *data, bool *handled);
int  n3vk_start(char *err, size_t err_len);
void n3vk_readback(unsigned width, unsigned height, n3_video_fn out);
void n3vk_context_destroy(void);
void n3vk_stop(void);
bool n3vk_active(void);

static struct {
    void *handle;
    void (*set_environment)(retro_environment_t);
    void (*set_video_refresh)(retro_video_refresh_t);
    void (*set_audio_sample)(retro_audio_sample_t);
    void (*set_audio_sample_batch)(retro_audio_sample_batch_t);
    void (*set_input_poll)(retro_input_poll_t);
    void (*set_input_state)(retro_input_state_t);
    void (*init)(void);
    void (*deinit)(void);
    void (*get_system_av_info)(struct retro_system_av_info *);
    bool (*load_game)(const struct retro_game_info *);
    void (*unload_game)(void);
    void (*run)(void);
    bool game_loaded;
    /* optional: only the Nasty3DS build of the core has these */
    int (*room_init)(void);
    int (*room_host)(const char *, unsigned short, unsigned);
    int (*room_join)(const char *, const char *, unsigned short);
    void (*room_leave)(void);
    int (*room_state)(void);
    int (*room_members)(char *, unsigned long);
    void (*room_shutdown)(void);
    size_t (*sfx_read)(int16_t *, size_t);
} core;

static n3_config cfg;

/* The tilt sensor, in g. Written on the main thread, read on the emulation thread, so each number
   is atomic. One frame may see a mix of the old and the new value, and that does no harm. */
static _Atomic float accel[3] = {0, -1, 0};
void n3_set_accel(float x, float y, float z) { accel[0] = x; accel[1] = y; accel[2] = z; }
static bool sensor_state(unsigned port, enum retro_sensor_action action, unsigned rate) {
    (void)port; (void)action; (void)rate;
    return true;
}
/* The accelerometer ids are 0, 1, 2. The console does not turn, so the gyroscope reads 0. */
static float sensor_input(unsigned port, unsigned id) { return port == 0 && id < 3 ? accel[id] : 0; }

static void host_log(int level, const char *fmt, ...) {
    if (!cfg.log) return;
    char line[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    cfg.log(level, line);
}

static void core_log(enum retro_log_level level, const char *fmt, ...) {
    if (!cfg.log) return;
    char line[2048];
    va_list ap;
    va_start(ap, fmt);
    vsnprintf(line, sizeof line, fmt, ap);
    va_end(ap);
    cfg.log((int)level, line);
}

static bool environment(unsigned cmd, void *data) {
    bool handled = false;
    bool result = n3vk_environment(cmd, data, &handled);
    if (handled) return result;
    switch (cmd) {
    case RETRO_ENVIRONMENT_SET_PIXEL_FORMAT:
        return *(const enum retro_pixel_format *)data == RETRO_PIXEL_FORMAT_XRGB8888;
    case RETRO_ENVIRONMENT_GET_SYSTEM_DIRECTORY:
        *(const char **)data = cfg.system_dir;
        return true;
    case RETRO_ENVIRONMENT_GET_SAVE_DIRECTORY:
        *(const char **)data = cfg.save_dir;
        return true;
    case RETRO_ENVIRONMENT_GET_LOG_INTERFACE:
        ((struct retro_log_callback *)data)->log = core_log;
        return true;
    case RETRO_ENVIRONMENT_GET_VARIABLE: {
        struct retro_variable *v = data;
        v->value = NULL;
        for (size_t i = 0; i < cfg.option_count; i++) {
            if (strcmp(cfg.options[i].key, v->key) == 0) v->value = cfg.options[i].value;
        }
        host_log(RETRO_LOG_DEBUG, "[n3] option %s = %s", v->key, v->value ? v->value : "(core default)");
        return v->value != NULL;
    }
    case RETRO_ENVIRONMENT_GET_VARIABLE_UPDATE:
        *(bool *)data = false;
        return true;
    case RETRO_ENVIRONMENT_GET_SENSOR_INTERFACE: {
        struct retro_sensor_interface *s = data;
        s->set_sensor_state = sensor_state;
        s->get_sensor_input = sensor_input;
        host_log(RETRO_LOG_INFO, "[n3] the core reads the tilt sensor from the host");
        return true;
    }
    case RETRO_ENVIRONMENT_GET_JIT_CAPABLE:
        *(bool *)data = true;
        return true;
    case RETRO_ENVIRONMENT_SET_MESSAGE:
        host_log(RETRO_LOG_INFO, "[core message] %s", ((const struct retro_message *)data)->msg);
        return true;
    case RETRO_ENVIRONMENT_SET_INPUT_DESCRIPTORS:
    case RETRO_ENVIRONMENT_SET_CONTROLLER_INFO:
    case RETRO_ENVIRONMENT_SET_VARIABLES:
    case RETRO_ENVIRONMENT_SET_GEOMETRY:
    case RETRO_ENVIRONMENT_SET_SERIALIZATION_QUIRKS:
    case RETRO_ENVIRONMENT_SET_MEMORY_MAPS:
        return true;
    default:
        host_log(RETRO_LOG_DEBUG, "[n3] environment %u not handled", cmd);
        return false;
    }
}

static void video_refresh(const void *data, unsigned width, unsigned height, size_t pitch) {
    if (!data || !cfg.video) return;
    if (data == RETRO_HW_FRAME_BUFFER_VALID) {
        n3vk_readback(width, height, cfg.video);
    } else {
        cfg.video(data, width, height, pitch);
    }
}

static void audio_sample(int16_t left, int16_t right) {
    int16_t pair[2] = {left, right};
    if (cfg.audio) cfg.audio(pair, 1);
}

static size_t audio_batch(const int16_t *data, size_t frames) {
    return cfg.audio ? cfg.audio(data, frames) : frames;
}

static void input_poll(void) {}

static int16_t input_state(unsigned port, unsigned device, unsigned index, unsigned id) {
    return cfg.input ? cfg.input(port, device, index, id) : 0;
}

#define SYM(field, name)                                                   \
    do {                                                                   \
        *(void **)&core.field = dlsym(core.handle, name);                  \
        if (!core.field) {                                                 \
            snprintf(err, err_len, "core has no symbol %s", name);         \
            dlclose(core.handle);                                          \
            core.handle = NULL;                                            \
            return 1;                                                      \
        }                                                                  \
    } while (0)

int n3_load_core(const char *dylib_path, const n3_config *config, char *err, size_t err_len) {
    if (core.handle) {
        snprintf(err, err_len, "a core is already loaded; call n3_unload first");
        return 1;
    }
    cfg = *config;
    core.handle = dlopen(dylib_path, RTLD_NOW | RTLD_LOCAL);
    if (!core.handle) {
        snprintf(err, err_len, "%s", dlerror());
        return 1;
    }
    SYM(set_environment, "retro_set_environment");
    SYM(set_video_refresh, "retro_set_video_refresh");
    SYM(set_audio_sample, "retro_set_audio_sample");
    SYM(set_audio_sample_batch, "retro_set_audio_sample_batch");
    SYM(set_input_poll, "retro_set_input_poll");
    SYM(set_input_state, "retro_set_input_state");
    SYM(init, "retro_init");
    SYM(deinit, "retro_deinit");
    SYM(get_system_av_info, "retro_get_system_av_info");
    SYM(load_game, "retro_load_game");
    SYM(unload_game, "retro_unload_game");
    SYM(run, "retro_run");

    core.set_environment(environment);
    core.set_video_refresh(video_refresh);
    core.set_audio_sample(audio_sample);
    core.set_audio_sample_batch(audio_batch);
    core.set_input_poll(input_poll);
    core.set_input_state(input_state);
    core.init();

#define OPT(field, name) *(void **)&core.field = dlsym(core.handle, name)
    OPT(room_init, "nasty3ds_room_init");
    OPT(room_host, "nasty3ds_room_host");
    OPT(room_join, "nasty3ds_room_join");
    OPT(room_leave, "nasty3ds_room_leave");
    OPT(room_state, "nasty3ds_room_state");
    OPT(room_members, "nasty3ds_room_members");
    OPT(room_shutdown, "nasty3ds_room_shutdown");
    OPT(sfx_read, "nasty3ds_sfx_read");
    /* Before the game loads: the game's wireless service links to the network when it starts. */
    if (core.room_init && core.room_init() != 0) host_log(RETRO_LOG_WARN, "[n3] local play network did not start");
    return 0;
}

int n3_load_game(const char *game_path, char *err, size_t err_len) {
    if (!core.handle) { snprintf(err, err_len, "no core is loaded"); return 1; }
    struct retro_game_info info = {.path = game_path};
    core.game_loaded = core.load_game(&info);
    if (!core.game_loaded) {
        snprintf(err, err_len, "the core did not accept %s", game_path);
        return 1;
    }
    return n3vk_start(err, err_len);
}

void n3_av_info(unsigned *width, unsigned *height, double *fps, double *sample_rate) {
    struct retro_system_av_info av = {0};
    if (core.handle) core.get_system_av_info(&av);
    *width = av.geometry.base_width;
    *height = av.geometry.base_height;
    *fps = av.timing.fps;
    *sample_rate = av.timing.sample_rate;
}

void n3_run(void) {
    if (!core.handle || !core.game_loaded) return;
    core.run();
    if (core.sfx_read && cfg.effects) {
        static int16_t block[2 * 1024];
        size_t frames;
        while ((frames = core.sfx_read(block, 1024)) > 0) cfg.effects(block, frames);
    }
}

int n3_has_effects(void) { return core.handle && core.sfx_read; }

void n3_unload(void) {
    if (!core.handle) return;
    n3vk_context_destroy();
    if (core.game_loaded) core.unload_game();
    if (core.room_shutdown) core.room_shutdown();
    core.deinit();
    n3vk_stop();
    dlclose(core.handle);
    memset(&core, 0, sizeof core);
}

int n3_room_host(const char *nickname, unsigned short port, unsigned max_players) {
    return core.handle && core.room_host ? core.room_host(nickname, port, max_players) : -1;
}
int n3_room_join(const char *nickname, const char *address, unsigned short port) {
    return core.handle && core.room_join ? core.room_join(nickname, address, port) : -1;
}
void n3_room_leave(void) { if (core.handle && core.room_leave) core.room_leave(); }
int n3_room_state(void) { return core.handle && core.room_state ? core.room_state() : -1; }
int n3_room_members(char *out, unsigned long length) {
    if (out && length) out[0] = 0;
    return core.handle && core.room_members ? core.room_members(out, length) : -1;
}
