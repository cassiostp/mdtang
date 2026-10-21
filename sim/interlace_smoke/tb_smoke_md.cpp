// Genesis smoke capture (Verilator, headless, no SDL).
//
// Full mdtang_top model (VERILATOR branch) with the ROM streamed through
// the loader_do path like verilator/sim_main.cpp. Scripted joypad input
// from a frame script; per-frame video hash + PPM dumps at selected frames;
// 16-bit stereo audio dump @48 kHz; SRAM window at end.
//
// Frame counting: vblank resets y (same scheme as the top's own HDMI
// framebuffer logic); a frame ends at the vblank rising edge.
// Usage: smoke_md <rom> <frames> <tag> [script] [dumplist]
#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <cstdint>
#include <vector>
#include <utility>

#include "Vmdtang_top.h"
#include "Vmdtang_top_mdtang_top.h"
#include "Vmdtang_top_system.h"
#include "Vmdtang_top_vdp.h"
#include "verilated.h"

#ifndef TANGCORE_SIM_THREADS
#define TANGCORE_SIM_THREADS 1
#endif

#define H_RES 320
#define V_RES 224

static Vmdtang_top *top;
static Vmdtang_top_mdtang_top *md;
static uint64_t sim_time = 0;

static uint64_t sys_next=9285714, pix_next=6734007;
static uint64_t pix_half=6734007;
static uint64_t now_fs=0;
static int hdmi_frames=0;
static uint8_t hdmi_img[1280*720*3];
static const char *capture_tag=nullptr;
static int video_w=1280, video_h=720;
static int vcnt_prev=485, field_prev=0, field_lines=0;
static uint64_t game_fields=0;
static uint64_t game_rate_start=0;
static inline void step() {
    if (sys_next <= pix_next) {
        now_fs=sys_next; sys_next+=9285714;
        if (top->clk_sys) top->clk_z80 = !top->clk_z80;
        top->clk_sys = !top->clk_sys;
        top->eval();
        sim_time++;
        if(top->clk_sys && md) {
            auto v=md->megadrive->vdp;
            if(v->__PVT__HV_VCNT!=vcnt_prev) field_lines++;
            if(v->__PVT__FIELD!=field_prev) {
                if(md->interlace_any) {
                    game_fields++;
                    if(game_fields==8) game_rate_start=now_fs;
                    if(game_fields>8 && game_fields%30==0) fprintf(stderr,"GAME_RATE fields=%llu hz=%.9f\n",(unsigned long long)(game_fields-8),(game_fields-8)*1e15/double(now_fs-game_rate_start));
                    if(game_fields<=40 || game_fields%60==0) fprintf(stderr,"GAMEFIELD %llu lines=%d parity=%d time_ms=%.9f\n",(unsigned long long)game_fields,field_lines,v->__PVT__FIELD,now_fs/1e12);
                }
                field_lines=0;
            }
            field_prev=v->__PVT__FIELD;vcnt_prev=v->__PVT__HV_VCNT;
        }
    } else {
        now_fs=pix_next; pix_next+=pix_half;
        top->clk_pixel_sim = !top->clk_pixel_sim;
        top->eval();
        if(top->clk_pixel_sim && capture_tag) {
            if(md->__PVT__fb__DOT__ilace_pixel && md->__PVT__fb__DOT__ilace_valid==3 && md->__PVT__fb__DOT__ilace_write &&
               (md->__PVT__fb__DOT__ilace_wr_bank==md->__PVT__fb__DOT__ilace_bank_even || md->__PVT__fb__DOT__ilace_wr_bank==md->__PVT__fb__DOT__ilace_bank_odd)) {fprintf(stderr,"GAME BANK OWNERSHIP FAIL\n");std::abort();}
            auto x=top->video_cx_sim; auto y=top->video_cy_sim;
            if(x==1 && y==0) hdmi_frames++;
            if(x>=1 && x<=video_w && y<video_h) {
                auto c=top->video_rgb_sim;
                auto p=&hdmi_img[(y*video_w+x-1)*3];
                p[0]=c>>16;p[1]=c>>8;p[2]=c;
            }
            if(x==video_w && y==video_h-1 && md->interlace_dres && hdmi_frames%30==0) {
                char path[1024];snprintf(path,sizeof path,"%s_woven_%d.ppm",capture_tag,hdmi_frames);
                FILE *f=fopen(path,"wb");fprintf(f,"P6\n%d %d\n255\n",video_w,video_h);fwrite(hdmi_img,1,video_w*video_h*3,f);fclose(f);
            }
        }
    }
}
static inline void step_sys() { auto before=sim_time; do step(); while (sim_time==before || !top->clk_sys); }

static void md_load(uint8_t *rom, int size) {
    while (md->reset || !top->clk_sys) step();
    top->loading = 1;
    step_sys();
    for (int i = 0; i < size; i++) {
        step_sys();
        top->loader_do = rom[i];
        top->loader_do_valid = 1;
        for (int j = 0; j < 6; j++) { step_sys(); top->loader_do_valid = 0; }
    }
    top->loading = 0;
    step_sys();
}

static uint8_t scr[H_RES * V_RES * 3];

int main(int argc, char **argv) {
    Verilated::commandArgs(argc, argv);
    Verilated::threadContextp()->threads(TANGCORE_SIM_THREADS);
    fprintf(stderr, "model threads: %u\n", Verilated::threadContextp()->threads());
    if (argc < 4) { fprintf(stderr, "usage: smoke_md <rom> <frames> <tag> [script] [dumps]\n"); return 1; }
    const char *rompath = argv[1];
    long want_frames = atol(argv[2]);
    const char *tag = argv[3];
    std::vector<std::pair<long, uint16_t>> script;
    if (argc > 4) {
        FILE *sf = fopen(argv[4], "r");
        if (!sf) { fprintf(stderr, "cannot open script %s\n", argv[4]); return 1; }
        long fr; unsigned int btn;
        while (fscanf(sf, "%ld %x", &fr, &btn) == 2) script.push_back({fr, (uint16_t)btn});
        fclose(sf);
        printf("script: %zu entries\n", script.size());
    }
    bool dumpall[10000] = {false};
    if (argc > 5) {
        char *list = argv[5], *tok = strtok(list, ",");
        while (tok) { long f = atol(tok); if (f < 10000) dumpall[f] = true; tok = strtok(nullptr, ","); }
    }

    top = new Vmdtang_top;
    if(getenv("HZ120")) {pix_half=9259259;pix_next=pix_half;video_w=720;video_h=480;}
    top->video_config_sim=0;
    capture_tag=tag;
    md = top->mdtang_top;
    top->verilator_core_config = 1u << 21;
    top->verilator_sv_req = 0;
    top->verilator_sv_we = 0;
    top->verilator_sv_addr = 0;
    top->verilator_sv_din = 0;

    FILE *f = fopen(rompath, "rb");
    if (!f) { fprintf(stderr, "cannot open %s\n", rompath); return 1; }
    fseek(f, 0, SEEK_END); long size = ftell(f); fseek(f, 0, SEEK_SET);
    uint8_t *rom = (uint8_t *)malloc(size);
    if (fread(rom, 1, size, f) != (size_t)size) return 1;
    fclose(f);
    md_load(rom, size);
    free(rom);

    char path[1024];
    snprintf(path, sizeof path, "%s.log", tag);
    FILE *flog = fopen(path, "w");
    snprintf(path, sizeof path, "%s.aud", tag);
    FILE *faud = fopen(path, "wb");
    setvbuf(flog, NULL, _IOFBF, 1 << 20);

    long frame_count = 0, samples = 0;
    uint64_t next_audio_fs=now_fs;
    int pixel_x = 0, pixel_y = 0, hblank_r = 0, ce_pix_r = 0;
    bool hsync_seen = false, in_frame = false;
    uint64_t vhash = 1469598103934665603ULL;
    long frame_nz = 0;
    size_t script_idx = 0;
    bool prev_vblank = false;
    uint64_t field_first=0, field_last=0;
    int interlaced_fields=0;
    uint64_t last_field_fs=0;
    bool was_interlace=false;

    while (frame_count < want_frames) {
        step();
        if (md->vblank && !prev_vblank) {
            // Field lengths measured in elapsed time and active core clocks.
            if(md->interlace_any) {
                if(!was_interlace) {field_first=now_fs;interlaced_fields=0;}
                else interlaced_fields++;
                field_last=now_fs;
                fprintf(flog,"INTERLACE frame=%ld dres=%d parity=%d period_ms=%.9f fields_hz=%.9f\n",frame_count,md->interlace_dres,md->field,(now_fs-last_field_fs)/1e12,interlaced_fields*1e15/(double)(field_last-field_first));
            }
            was_interlace=md->interlace_any;last_field_fs=now_fs;
            // frame end: hash + log
            uint64_t fh = vhash;
            fprintf(flog, "F %ld samp=%ld vhash=%016lx nz=%ld\n",
                    frame_count, samples, (unsigned long)fh, frame_nz);
            if (frame_count < 10000 && dumpall[frame_count]) {
                snprintf(path, sizeof path, "%s_f%ld.ppm", tag, frame_count);
                FILE *pf = fopen(path, "wb");
                if (pf) {
                    fprintf(pf, "P6\n%d %d\n255\n", H_RES, V_RES);
                    fwrite(scr, 1, sizeof scr, pf);
                    fclose(pf);
                }
            }
            vhash = 1469598103934665603ULL;
            frame_nz = 0;
            memset(scr, 0, sizeof scr);
            frame_count++;
            if (frame_count % 100 == 0) { fprintf(stderr, "frame %ld\n", frame_count); fflush(flog); }
        }
        prev_vblank = md->vblank;
        if (md->vblank) { pixel_y = 0; hsync_seen = false; }
        if (md->hsync) hsync_seen = true;
        if (hsync_seen && md->hblank) {
            pixel_x = 0;
            if (!hblank_r) pixel_y++;
        }
        hblank_r = md->hblank;
        if (hsync_seen && md->ce_pix && !ce_pix_r && pixel_x < H_RES && pixel_y < V_RES) {
            uint8_t *p = &scr[(pixel_y * H_RES + pixel_x) * 3];
            p[0] = md->red << 4; p[1] = md->green << 4; p[2] = md->blue << 4;
            uint32_t px = (p[0] << 16) | (p[1] << 8) | p[2];
            vhash ^= px; vhash *= 1099511628211ULL;
            if (px) frame_nz++;
            pixel_x++;
        }
        ce_pix_r = md->ce_pix;
        // audio @48k
        if (now_fs >= next_audio_fs && md->md_on) {
            uint16_t al = md->audio_left, ar = md->audio_right;
            fwrite(&al, 2, 1, faud); fwrite(&ar, 2, 1, faud);
            samples++;
            next_audio_fs += 1000000000000000ULL / 48000;
        }
        // scripted input (joy_btns: SNES layout, same as sim_main keys)
        top->joy_btns = 0;
        top->joy2_btns = 0;
        while (script_idx < script.size() && script[script_idx].first <= frame_count) {
            script_idx++;
        }
        if (script_idx > 0 && script_idx <= script.size())
            top->joy_btns = script[script_idx - 1].second;
        (void)in_frame;
    }
    // SRAM window 128 KB at 0x820000 (sdram_sim 16-bit words, byte addr/2)
    {
        char sb[1024]; snprintf(sb, sizeof sb, "%s_save.bin", tag);
        FILE *fs = fopen(sb, "wb");
        uint64_t sh = 1469598103934665603ULL;
        auto &mem = md->__PVT__u_sdram__DOT__mem;
        for (uint32_t a = 0; a < 0x20000; a += 2) {
            uint16_t w = mem[(0x820000 + a) >> 1];
            uint8_t b[2] = {(uint8_t)(w & 0xFF), (uint8_t)(w >> 8)};
            if (fs) fwrite(b, 1, 2, fs);
            sh ^= b[0]; sh *= 1099511628211ULL; sh ^= b[1]; sh *= 1099511628211ULL;
        }
        if (fs) fclose(fs);
        fprintf(flog, "# save hash=%016lx\n", (unsigned long)sh);
    }
    fprintf(flog, "END frames=%ld samples=%ld\n", frame_count, samples);
    printf("done: frames=%ld samples=%ld sim_time=%lu\n",
           frame_count, samples, (unsigned long)sim_time);
    fprintf(flog,"INTERLACE_TOTAL fields=%d rate=%.9f\n",interlaced_fields,interlaced_fields*1e15/(double)(field_last-field_first));
    fclose(flog); fclose(faud);
    return 0;
}
