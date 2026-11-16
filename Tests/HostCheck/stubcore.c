// Fake libretro core: counts init calls, detects two threads inside retro_run, sends one frame per run.
#include "libretro.h"
#include <stdio.h>
#include <stdatomic.h>
#include <unistd.h>
#include <string.h>
static retro_environment_t env; static retro_video_refresh_t video; static retro_input_state_t input;
static atomic_int in_run, inits, loads, overlaps, runs, deinits;
static uint32_t fb[400*480];
void retro_set_environment(retro_environment_t cb){env=cb;}
void retro_set_video_refresh(retro_video_refresh_t cb){video=cb;}
void retro_set_audio_sample(retro_audio_sample_t cb){}
void retro_set_audio_sample_batch(retro_audio_sample_batch_t cb){}
void retro_set_input_poll(retro_input_poll_t cb){}
void retro_set_input_state(retro_input_state_t cb){input=cb;}
void retro_init(void){ fprintf(stderr,"[stub] retro_init call #%d\n", ++inits); }
void retro_deinit(void){ fprintf(stderr,"[stub] retro_deinit call #%d (threads in retro_run right now: %d)\n", ++deinits, (int)in_run); }
void retro_get_system_av_info(struct retro_system_av_info *i){ memset(i,0,sizeof *i); i->geometry.base_width=400;i->geometry.base_height=480;i->timing.fps=60;i->timing.sample_rate=32728; }
bool retro_load_game(const struct retro_game_info *g){ fprintf(stderr,"[stub] retro_load_game call #%d\n", ++loads); return strstr(g->path,"bad")==NULL; }
void retro_unload_game(void){ fprintf(stderr,"[stub] retro_unload_game\n"); }
void retro_run(void){
  if (atomic_fetch_add(&in_run,1) != 0) { if (++overlaps == 1) fprintf(stderr,"[stub] TWO THREADS INSIDE retro_run AT ONCE\n"); }
  runs++;
  for (int y=0;y<480;y++) for(int x=0;x<400;x++) fb[y*400+x] = y<240 ? 0x00FF0000 : 0x000000FF; // top red, bottom blue
  if (input) input(0,1,0,0);
  usleep(3000);
  if (video) video(fb,400,480,400*4);
  atomic_fetch_sub(&in_run,1);
}
int stub_overlaps(void){return overlaps;} int stub_runs(void){return runs;}
