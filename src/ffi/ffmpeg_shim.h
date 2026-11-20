#ifndef OPENSCREEN_FFMPEG_SHIM_H
#define OPENSCREEN_FFMPEG_SHIM_H

#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OscDemuxer OscDemuxer;
typedef struct OscMuxer OscMuxer;
typedef struct OscGifMuxer OscGifMuxer;

/* Error helper: returns AVERROR(EAGAIN) on this platform */
int osc_averror_eagain(void);

/* Hardware encoder probe */
int osc_probe_best_h264_encoder(char *out_name, size_t max_len);

/* Demuxer API */
int osc_demuxer_open(const char *filename, OscDemuxer **out_demuxer);
void osc_demuxer_close(OscDemuxer *d);

int osc_demuxer_has_video(const OscDemuxer *d);
int osc_demuxer_get_video_info(const OscDemuxer *d, int *width, int *height, int *fps_num, int *fps_den, int64_t *duration_ms, int64_t *nb_frames);

int osc_demuxer_has_audio(const OscDemuxer *d);
int osc_demuxer_get_audio_info(const OscDemuxer *d, int *sample_rate, int *channels, int64_t *duration_ms);

int osc_demuxer_seek_frame(OscDemuxer *d, int64_t target_pts_ms);
int osc_demuxer_read_video_frame(OscDemuxer *d, uint8_t *out_rgba, int64_t *out_pts_ms, int *is_eof);

int osc_demuxer_seek_audio(OscDemuxer *d, int64_t target_pts_ms);
int osc_demuxer_read_audio_samples(OscDemuxer *d, float *out_pcm, int max_samples, int *out_samples, int64_t *out_pts_ms, int *is_eof);

/* MP4 Muxer API (H.264 + AAC) */
int osc_muxer_open(
    const char *filename,
    int width,
    int height,
    int fps_num,
    int fps_den,
    int video_bitrate,
    int audio_sample_rate,
    int audio_channels,
    int audio_bitrate,
    const char *codec_override,
    OscMuxer **out_muxer
);
int osc_muxer_write_video_frame(OscMuxer *m, const uint8_t *rgba, int64_t pts_frame);
int osc_muxer_write_audio_samples(OscMuxer *m, const float *pcm_interleaved, int num_samples, int64_t pts_sample);
int osc_muxer_flush(OscMuxer *m);
int osc_muxer_close(OscMuxer *m);

/* GIF Muxer API */
int osc_gif_muxer_open(const char *filename, int width, int height, int fps_num, int fps_den, OscGifMuxer **out_gif);
int osc_gif_muxer_write_frame(OscGifMuxer *g, const uint8_t *rgba, int64_t pts_frame);
int osc_gif_muxer_close(OscGifMuxer *g);

#ifdef __cplusplus
}
#endif

#endif /* OPENSCREEN_FFMPEG_SHIM_H */
