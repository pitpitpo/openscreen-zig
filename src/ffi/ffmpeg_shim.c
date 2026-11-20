#include "ffmpeg_shim.h"

#include <libavcodec/avcodec.h>
#include <libavformat/avformat.h>
#include <libavutil/avutil.h>
#include <libavutil/imgutils.h>
#include <libavutil/opt.h>
#include <libavutil/mathematics.h>
#include <libavutil/channel_layout.h>
#include <libswscale/swscale.h>
#include <libswresample/swresample.h>

#include <stdlib.h>
#include <string.h>
#include <stdio.h>

int osc_averror_eagain(void) {
    return AVERROR(EAGAIN);
}

static int test_h264_encoder(const char *name) {
    if (!name) return 0;
    const AVCodec *codec = avcodec_find_encoder_by_name(name);
    if (!codec) return 0;

    AVCodecContext *ctx = avcodec_alloc_context3(codec);
    if (!ctx) return 0;

    ctx->width = 320;
    ctx->height = 240;
    ctx->time_base = (AVRational){ 1, 30 };
    ctx->pix_fmt = AV_PIX_FMT_YUV420P;

    int prev_level = av_log_get_level();
    av_log_set_level(AV_LOG_QUIET);
    int ret = avcodec_open2(ctx, codec, NULL);
    av_log_set_level(prev_level);

    avcodec_free_context(&ctx);
    return (ret >= 0);
}

int osc_probe_best_h264_encoder(char *out_name, size_t max_len) {
    if (!out_name || max_len == 0) return -1;

    static const char *candidates[] = {
        "h264_videotoolbox", /* macOS Apple Silicon / Intel VT */
        "h264_nvenc",       /* NVIDIA NVENC */
        "h264_amf",         /* AMD AMF */
        "h264_qsv",         /* Intel QuickSync */
        "h264_vaapi",       /* Linux VAAPI */
        "libopenh264",      /* Cisco openh264 LGPL */
        "h264",             /* Host default / wrapper */
        "libx264",          /* Generic fallback */
        NULL
    };

    for (int i = 0; candidates[i] != NULL; ++i) {
        if (test_h264_encoder(candidates[i])) {
            snprintf(out_name, max_len, "%s", candidates[i]);
            return 0;
        }
    }

    for (int i = 0; candidates[i] != NULL; ++i) {
        if (avcodec_find_encoder_by_name(candidates[i])) {
            snprintf(out_name, max_len, "%s", candidates[i]);
            return 0;
        }
    }

    snprintf(out_name, max_len, "h264");
    return 0;
}

/* ========================================================================= */
/*                              DEMUXER                                      */
/* ========================================================================= */

struct OscDemuxer {
    AVFormatContext *fmt_ctx;
    int video_stream_idx;
    int audio_stream_idx;

    AVCodecContext *video_dec_ctx;
    AVCodecContext *audio_dec_ctx;

    struct SwsContext *sws_ctx;
    int sws_src_w;
    int sws_src_h;
    enum AVPixelFormat sws_src_fmt;

    SwrContext *swr_ctx;
    int swr_src_rate;
    int swr_src_channels;
    enum AVSampleFormat swr_src_fmt;

    AVPacket *pkt;
    AVFrame *frame;
    AVFrame *rgba_frame;

    int64_t last_video_pts_ms;
    int64_t last_audio_pts_ms;
};

int osc_demuxer_open(const char *filename, OscDemuxer **out_demuxer) {
    if (!filename || !out_demuxer) return -1;
    *out_demuxer = NULL;

    OscDemuxer *d = (OscDemuxer *)calloc(1, sizeof(OscDemuxer));
    if (!d) return -1;

    d->video_stream_idx = -1;
    d->audio_stream_idx = -1;

    if (avformat_open_input(&d->fmt_ctx, filename, NULL, NULL) < 0) {
        free(d);
        return -1;
    }

    if (avformat_find_stream_info(d->fmt_ctx, NULL) < 0) {
        avformat_close_input(&d->fmt_ctx);
        free(d);
        return -1;
    }

    /* Locate video stream */
    for (unsigned int i = 0; i < d->fmt_ctx->nb_streams; ++i) {
        if (d->fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_VIDEO && d->video_stream_idx < 0) {
            d->video_stream_idx = (int)i;
        } else if (d->fmt_ctx->streams[i]->codecpar->codec_type == AVMEDIA_TYPE_AUDIO && d->audio_stream_idx < 0) {
            d->audio_stream_idx = (int)i;
        }
    }

    /* Initialize Video Decoder */
    if (d->video_stream_idx >= 0) {
        AVStream *st = d->fmt_ctx->streams[d->video_stream_idx];
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        if (codec) {
            d->video_dec_ctx = avcodec_alloc_context3(codec);
            if (d->video_dec_ctx) {
                if (avcodec_parameters_to_context(d->video_dec_ctx, st->codecpar) >= 0) {
                    if (avcodec_open2(d->video_dec_ctx, codec, NULL) < 0) {
                        avcodec_free_context(&d->video_dec_ctx);
                        d->video_dec_ctx = NULL;
                    }
                } else {
                    avcodec_free_context(&d->video_dec_ctx);
                    d->video_dec_ctx = NULL;
                }
            }
        }
    }

    /* Initialize Audio Decoder */
    if (d->audio_stream_idx >= 0) {
        AVStream *st = d->fmt_ctx->streams[d->audio_stream_idx];
        const AVCodec *codec = avcodec_find_decoder(st->codecpar->codec_id);
        if (codec) {
            d->audio_dec_ctx = avcodec_alloc_context3(codec);
            if (d->audio_dec_ctx) {
                if (avcodec_parameters_to_context(d->audio_dec_ctx, st->codecpar) >= 0) {
                    if (avcodec_open2(d->audio_dec_ctx, codec, NULL) < 0) {
                        avcodec_free_context(&d->audio_dec_ctx);
                        d->audio_dec_ctx = NULL;
                    }
                } else {
                    avcodec_free_context(&d->audio_dec_ctx);
                    d->audio_dec_ctx = NULL;
                }
            }
        }
    }

    d->pkt = av_packet_alloc();
    d->frame = av_frame_alloc();
    d->rgba_frame = av_frame_alloc();

    if (!d->pkt || !d->frame || !d->rgba_frame) {
        osc_demuxer_close(d);
        return -1;
    }

    *out_demuxer = d;
    return 0;
}

void osc_demuxer_close(OscDemuxer *d) {
    if (!d) return;

    if (d->sws_ctx) {
        sws_freeContext(d->sws_ctx);
        d->sws_ctx = NULL;
    }
    if (d->swr_ctx) {
        swr_free(&d->swr_ctx);
        d->swr_ctx = NULL;
    }
    if (d->video_dec_ctx) {
        avcodec_free_context(&d->video_dec_ctx);
        d->video_dec_ctx = NULL;
    }
    if (d->audio_dec_ctx) {
        avcodec_free_context(&d->audio_dec_ctx);
        d->audio_dec_ctx = NULL;
    }
    if (d->frame) {
        av_frame_free(&d->frame);
        d->frame = NULL;
    }
    if (d->rgba_frame) {
        av_frame_free(&d->rgba_frame);
        d->rgba_frame = NULL;
    }
    if (d->pkt) {
        av_packet_free(&d->pkt);
        d->pkt = NULL;
    }
    if (d->fmt_ctx) {
        avformat_close_input(&d->fmt_ctx);
        d->fmt_ctx = NULL;
    }
    free(d);
}

int osc_demuxer_has_video(const OscDemuxer *d) {
    return (d && d->video_stream_idx >= 0 && d->video_dec_ctx != NULL);
}

int osc_demuxer_get_video_info(const OscDemuxer *d, int *width, int *height, int *fps_num, int *fps_den, int64_t *duration_ms, int64_t *nb_frames) {
    if (!osc_demuxer_has_video(d)) return -1;
    AVStream *st = d->fmt_ctx->streams[d->video_stream_idx];

    if (width) *width = d->video_dec_ctx->width;
    if (height) *height = d->video_dec_ctx->height;

    AVRational rate = av_guess_frame_rate(d->fmt_ctx, st, NULL);
    if (rate.num <= 0 || rate.den <= 0) {
        rate.num = 30;
        rate.den = 1;
    }
    if (fps_num) *fps_num = rate.num;
    if (fps_den) *fps_den = rate.den;

    int64_t dur_ms = 0;
    if (st->duration > 0 && st->time_base.den > 0) {
        dur_ms = av_rescale_q(st->duration, st->time_base, (AVRational){1, 1000});
    } else if (d->fmt_ctx->duration > 0) {
        dur_ms = d->fmt_ctx->duration / (AV_TIME_BASE / 1000);
    }
    if (duration_ms) *duration_ms = dur_ms;

    int64_t frames = st->nb_frames;
    if (frames <= 0 && dur_ms > 0 && rate.den > 0) {
        frames = (dur_ms * rate.num) / (rate.den * 1000);
    }
    if (nb_frames) *nb_frames = frames;

    return 0;
}

int osc_demuxer_has_audio(const OscDemuxer *d) {
    return (d && d->audio_stream_idx >= 0 && d->audio_dec_ctx != NULL);
}

int osc_demuxer_get_audio_info(const OscDemuxer *d, int *sample_rate, int *channels, int64_t *duration_ms) {
    if (!osc_demuxer_has_audio(d)) return -1;
    AVStream *st = d->fmt_ctx->streams[d->audio_stream_idx];

    if (sample_rate) *sample_rate = d->audio_dec_ctx->sample_rate;

    int ch = 0;
#if LIBAVUTIL_VERSION_INT >= AV_VERSION_INT(57, 28, 100)
    ch = d->audio_dec_ctx->ch_layout.nb_channels;
#else
    ch = d->audio_dec_ctx->channels;
#endif
    if (ch <= 0) ch = 2;
    if (channels) *channels = ch;

    int64_t dur_ms = 0;
    if (st->duration > 0 && st->time_base.den > 0) {
        dur_ms = av_rescale_q(st->duration, st->time_base, (AVRational){1, 1000});
    } else if (d->fmt_ctx->duration > 0) {
        dur_ms = d->fmt_ctx->duration / (AV_TIME_BASE / 1000);
    }
    if (duration_ms) *duration_ms = dur_ms;

    return 0;
}

int osc_demuxer_seek_frame(OscDemuxer *d, int64_t target_pts_ms) {
    if (!osc_demuxer_has_video(d)) return -1;
    AVStream *st = d->fmt_ctx->streams[d->video_stream_idx];

    int64_t ts = av_rescale_q(target_pts_ms, (AVRational){1, 1000}, st->time_base);
    int ret = av_seek_frame(d->fmt_ctx, d->video_stream_idx, ts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) {
        ret = av_seek_frame(d->fmt_ctx, -1, target_pts_ms * 1000, AVSEEK_FLAG_BACKWARD);
    }

    if (d->video_dec_ctx) avcodec_flush_buffers(d->video_dec_ctx);
    if (d->audio_dec_ctx) avcodec_flush_buffers(d->audio_dec_ctx);

    return (ret >= 0) ? 0 : -1;
}

int osc_demuxer_seek_audio(OscDemuxer *d, int64_t target_pts_ms) {
    if (!osc_demuxer_has_audio(d)) return -1;
    AVStream *st = d->fmt_ctx->streams[d->audio_stream_idx];

    int64_t ts = av_rescale_q(target_pts_ms, (AVRational){1, 1000}, st->time_base);
    int ret = av_seek_frame(d->fmt_ctx, d->audio_stream_idx, ts, AVSEEK_FLAG_BACKWARD);
    if (ret < 0) {
        ret = av_seek_frame(d->fmt_ctx, -1, target_pts_ms * 1000, AVSEEK_FLAG_BACKWARD);
    }

    if (d->audio_dec_ctx) avcodec_flush_buffers(d->audio_dec_ctx);
    return (ret >= 0) ? 0 : -1;
}

int osc_demuxer_read_video_frame(OscDemuxer *d, uint8_t *out_rgba, int64_t *out_pts_ms, int *is_eof) {
    if (!osc_demuxer_has_video(d) || !out_rgba) return -1;
    if (is_eof) *is_eof = 0;

    AVStream *st = d->fmt_ctx->streams[d->video_stream_idx];

    while (1) {
        int ret = avcodec_receive_frame(d->video_dec_ctx, d->frame);
        if (ret == 0) {
            /* Frame decoded successfully */
            int w = d->video_dec_ctx->width;
            int h = d->video_dec_ctx->height;

            if (!d->sws_ctx || d->sws_src_w != w || d->sws_src_h != h || d->sws_src_fmt != d->video_dec_ctx->pix_fmt) {
                if (d->sws_ctx) sws_freeContext(d->sws_ctx);
                d->sws_ctx = sws_getContext(
                    w, h, d->video_dec_ctx->pix_fmt,
                    w, h, AV_PIX_FMT_RGBA,
                    SWS_BILINEAR, NULL, NULL, NULL
                );
                d->sws_src_w = w;
                d->sws_src_h = h;
                d->sws_src_fmt = d->video_dec_ctx->pix_fmt;
            }

            uint8_t *dst_data[4] = { out_rgba, NULL, NULL, NULL };
            int dst_linesize[4] = { w * 4, 0, 0, 0 };

            sws_scale(
                d->sws_ctx,
                (const uint8_t * const *)d->frame->data,
                d->frame->linesize,
                0,
                h,
                dst_data,
                dst_linesize
            );

            int64_t pts = d->frame->best_effort_timestamp;
            if (pts == AV_NOPTS_VALUE) pts = d->frame->pts;
            int64_t pts_ms = 0;
            if (pts != AV_NOPTS_VALUE) {
                pts_ms = av_rescale_q(pts, st->time_base, (AVRational){1, 1000});
            } else {
                pts_ms = d->last_video_pts_ms + 33;
            }
            d->last_video_pts_ms = pts_ms;
            if (out_pts_ms) *out_pts_ms = pts_ms;

            return 0;
        }

        if (ret == AVERROR_EOF) {
            if (is_eof) *is_eof = 1;
            return 0;
        }

        if (ret != AVERROR(EAGAIN)) {
            return -1;
        }

        /* Need more packets */
        int read_ret = av_read_frame(d->fmt_ctx, d->pkt);
        if (read_ret < 0) {
            if (read_ret == AVERROR_EOF) {
                /* Flush decoder */
                avcodec_send_packet(d->video_dec_ctx, NULL);
                continue;
            }
            return -1;
        }

        if (d->pkt->stream_index == d->video_stream_idx) {
            int send_ret = avcodec_send_packet(d->video_dec_ctx, d->pkt);
            av_packet_unref(d->pkt);
            if (send_ret < 0 && send_ret != AVERROR(EAGAIN)) {
                return -1;
            }
        } else {
            av_packet_unref(d->pkt);
        }
    }
}

int osc_demuxer_read_audio_samples(OscDemuxer *d, float *out_pcm, int max_samples, int *out_samples, int64_t *out_pts_ms, int *is_eof) {
    if (!osc_demuxer_has_audio(d) || !out_pcm || max_samples <= 0) return -1;
    if (out_samples) *out_samples = 0;
    if (is_eof) *is_eof = 0;

    AVStream *st = d->fmt_ctx->streams[d->audio_stream_idx];

    while (1) {
        int ret = avcodec_receive_frame(d->audio_dec_ctx, d->frame);
        if (ret == 0) {
            /* Frame decoded */
            int in_rate = d->audio_dec_ctx->sample_rate;
            int in_channels = 0;
#if LIBAVUTIL_VERSION_INT >= AV_VERSION_INT(57, 28, 100)
            in_channels = d->audio_dec_ctx->ch_layout.nb_channels;
#else
            in_channels = d->audio_dec_ctx->channels;
#endif
            if (in_channels <= 0) in_channels = 2;

            if (!d->swr_ctx || d->swr_src_rate != in_rate || d->swr_src_channels != in_channels || d->swr_src_fmt != d->audio_dec_ctx->sample_fmt) {
                if (d->swr_ctx) swr_free(&d->swr_ctx);

#if LIBAVUTIL_VERSION_INT >= AV_VERSION_INT(57, 28, 100)
                AVChannelLayout out_ch_layout;
                av_channel_layout_default(&out_ch_layout, 2);
                swr_alloc_set_opts2(
                    &d->swr_ctx,
                    &out_ch_layout,
                    AV_SAMPLE_FMT_FLT,
                    in_rate,
                    &d->audio_dec_ctx->ch_layout,
                    d->audio_dec_ctx->sample_fmt,
                    in_rate,
                    0, NULL
                );
#else
                d->swr_ctx = swr_alloc_set_opts(
                    NULL,
                    AV_CH_LAYOUT_STEREO,
                    AV_SAMPLE_FMT_FLT,
                    in_rate,
                    d->audio_dec_ctx->channel_layout ? d->audio_dec_ctx->channel_layout : av_get_default_channel_layout(in_channels),
                    d->audio_dec_ctx->sample_fmt,
                    in_rate,
                    0, NULL
                );
#endif
                swr_init(d->swr_ctx);
                d->swr_src_rate = in_rate;
                d->swr_src_channels = in_channels;
                d->swr_src_fmt = d->audio_dec_ctx->sample_fmt;
            }

            uint8_t *out_planes[1] = { (uint8_t *)out_pcm };
            int converted = swr_convert(
                d->swr_ctx,
                out_planes,
                max_samples,
                (const uint8_t **)d->frame->data,
                d->frame->nb_samples
            );

            if (converted < 0) converted = 0;
            if (out_samples) *out_samples = converted;

            int64_t pts = d->frame->best_effort_timestamp;
            if (pts == AV_NOPTS_VALUE) pts = d->frame->pts;
            int64_t pts_ms = 0;
            if (pts != AV_NOPTS_VALUE) {
                pts_ms = av_rescale_q(pts, st->time_base, (AVRational){1, 1000});
            } else {
                pts_ms = d->last_audio_pts_ms;
            }
            d->last_audio_pts_ms = pts_ms;
            if (out_pts_ms) *out_pts_ms = pts_ms;

            return 0;
        }

        if (ret == AVERROR_EOF) {
            if (is_eof) *is_eof = 1;
            return 0;
        }

        if (ret != AVERROR(EAGAIN)) {
            return -1;
        }

        int read_ret = av_read_frame(d->fmt_ctx, d->pkt);
        if (read_ret < 0) {
            if (read_ret == AVERROR_EOF) {
                avcodec_send_packet(d->audio_dec_ctx, NULL);
                continue;
            }
            return -1;
        }

        if (d->pkt->stream_index == d->audio_stream_idx) {
            int send_ret = avcodec_send_packet(d->audio_dec_ctx, d->pkt);
            av_packet_unref(d->pkt);
            if (send_ret < 0 && send_ret != AVERROR(EAGAIN)) {
                return -1;
            }
        } else {
            av_packet_unref(d->pkt);
        }
    }
}

/* ========================================================================= */
/*                               MUXER (MP4)                                 */
/* ========================================================================= */

struct OscMuxer {
    AVFormatContext *fmt_ctx;

    AVStream *video_stream;
    AVCodecContext *video_enc_ctx;
    struct SwsContext *sws_ctx;
    AVFrame *yuv_frame;
    int width;
    int height;
    int fps_num;
    int fps_den;

    AVStream *audio_stream;
    AVCodecContext *audio_enc_ctx;
    SwrContext *swr_ctx;
    AVFrame *audio_frame;
    int audio_sample_rate;
    int audio_channels;
    int audio_frame_size;
    float *audio_buffer;
    int audio_buf_count;
    int audio_buf_capacity;

    int64_t next_audio_pts;

    AVPacket *pkt;
};

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
) {
    if (!filename || !out_muxer || width <= 0 || height <= 0 || fps_num <= 0 || fps_den <= 0) return -1;
    *out_muxer = NULL;

    OscMuxer *m = (OscMuxer *)calloc(1, sizeof(OscMuxer));
    if (!m) return -1;

    m->width = width;
    m->height = height;
    m->fps_num = fps_num;
    m->fps_den = fps_den;
    m->audio_sample_rate = audio_sample_rate > 0 ? audio_sample_rate : 44100;
    m->audio_channels = audio_channels > 0 ? audio_channels : 2;

    int ret = avformat_alloc_output_context2(&m->fmt_ctx, NULL, "mp4", filename);
    if (ret < 0 || !m->fmt_ctx) {
        free(m);
        return -1;
    }

    /* Video Encoder */
    static const char *h264_candidates[] = {
        "h264_videotoolbox",
        "h264_nvenc",
        "h264_amf",
        "h264_qsv",
        "h264_vaapi",
        "libopenh264",
        "libx264",
        "h264",
        NULL
    };

    const AVCodec *v_codec = NULL;
    if (codec_override && strlen(codec_override) > 0) {
        v_codec = avcodec_find_encoder_by_name(codec_override);
    }
    if (!v_codec) {
        char best[64];
        if (osc_probe_best_h264_encoder(best, sizeof(best)) == 0) {
            v_codec = avcodec_find_encoder_by_name(best);
        }
    }
    if (!v_codec) {
        v_codec = avcodec_find_encoder(AV_CODEC_ID_H264);
    }

    m->video_stream = avformat_new_stream(m->fmt_ctx, NULL);
    if (!m->video_stream) {
        avformat_free_context(m->fmt_ctx);
        free(m);
        return -1;
    }

    int open_ok = 0;
    int cand_idx = -1;
    while (!open_ok) {
        if (!v_codec) {
            cand_idx++;
            if (h264_candidates[cand_idx] == NULL) break;
            v_codec = avcodec_find_encoder_by_name(h264_candidates[cand_idx]);
            if (!v_codec) continue;
        }

        m->video_enc_ctx = avcodec_alloc_context3(v_codec);
        if (!m->video_enc_ctx) {
            v_codec = NULL;
            continue;
        }

        m->video_enc_ctx->width = width;
        m->video_enc_ctx->height = height;
        m->video_enc_ctx->time_base = (AVRational){ fps_den, fps_num };
        m->video_stream->time_base = (AVRational){ fps_den, fps_num };
        m->video_enc_ctx->framerate = (AVRational){ fps_num, fps_den };
        m->video_enc_ctx->pix_fmt = AV_PIX_FMT_YUV420P;
        m->video_enc_ctx->bit_rate = video_bitrate > 0 ? video_bitrate : 4000000;
        m->video_enc_ctx->gop_size = 12;

        if (m->fmt_ctx->oformat->flags & AVFMT_GLOBALHEADER) {
            m->video_enc_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
        }

        if (v_codec->name && strcmp(v_codec->name, "libx264") == 0) {
            av_opt_set(m->video_enc_ctx->priv_data, "preset", "fast", 0);
            av_opt_set(m->video_enc_ctx->priv_data, "tune", "film", 0);
        } else if (v_codec->name && strstr(v_codec->name, "nvenc")) {
            av_opt_set(m->video_enc_ctx->priv_data, "preset", "p4", 0);
        }

        int prev_level = av_log_get_level();
        av_log_set_level(AV_LOG_QUIET);
        int enc_ret = avcodec_open2(m->video_enc_ctx, v_codec, NULL);
        av_log_set_level(prev_level);

        if (enc_ret >= 0) {
            open_ok = 1;
            break;
        }

        avcodec_free_context(&m->video_enc_ctx);
        v_codec = NULL;
    }

    if (!open_ok || !m->video_enc_ctx) {
        avformat_free_context(m->fmt_ctx);
        free(m);
        return -1;
    }

    avcodec_parameters_from_context(m->video_stream->codecpar, m->video_enc_ctx);

    /* Allocate YUV frame */
    m->yuv_frame = av_frame_alloc();
    m->yuv_frame->format = m->video_enc_ctx->pix_fmt;
    m->yuv_frame->width = width;
    m->yuv_frame->height = height;
    if (av_frame_get_buffer(m->yuv_frame, 32) < 0) {
        osc_muxer_close(m);
        return -1;
    }

    m->sws_ctx = sws_getContext(
        width, height, AV_PIX_FMT_RGBA,
        width, height, m->video_enc_ctx->pix_fmt,
        SWS_BILINEAR, NULL, NULL, NULL
    );

    /* Audio Encoder */
    if (audio_channels > 0) {
        const AVCodec *a_codec = avcodec_find_encoder(AV_CODEC_ID_AAC);
        if (a_codec) {
            m->audio_stream = avformat_new_stream(m->fmt_ctx, NULL);
            if (m->audio_stream) {
                m->audio_enc_ctx = avcodec_alloc_context3(a_codec);
                if (m->audio_enc_ctx) {
                    m->audio_enc_ctx->sample_rate = m->audio_sample_rate;
#if LIBAVUTIL_VERSION_INT >= AV_VERSION_INT(57, 28, 100)
                    av_channel_layout_default(&m->audio_enc_ctx->ch_layout, m->audio_channels);
#else
                    m->audio_enc_ctx->channels = m->audio_channels;
                    m->audio_enc_ctx->channel_layout = av_get_default_channel_layout(m->audio_channels);
#endif
                    m->audio_enc_ctx->sample_fmt = AV_SAMPLE_FMT_FLTP;
                    m->audio_enc_ctx->bit_rate = audio_bitrate > 0 ? audio_bitrate : 128000;
                    m->audio_enc_ctx->time_base = (AVRational){ 1, m->audio_sample_rate };
                    m->audio_stream->time_base = (AVRational){ 1, m->audio_sample_rate };

                    if (m->fmt_ctx->oformat->flags & AVFMT_GLOBALHEADER) {
                        m->audio_enc_ctx->flags |= AV_CODEC_FLAG_GLOBAL_HEADER;
                    }

                    if (avcodec_open2(m->audio_enc_ctx, a_codec, NULL) == 0) {
                        avcodec_parameters_from_context(m->audio_stream->codecpar, m->audio_enc_ctx);
                        m->audio_frame_size = m->audio_enc_ctx->frame_size > 0 ? m->audio_enc_ctx->frame_size : 1024;

                        m->audio_frame = av_frame_alloc();
                        m->audio_frame->nb_samples = m->audio_frame_size;
                        m->audio_frame->format = m->audio_enc_ctx->sample_fmt;
#if LIBAVUTIL_VERSION_INT >= AV_VERSION_INT(57, 28, 100)
                        av_channel_layout_copy(&m->audio_frame->ch_layout, &m->audio_enc_ctx->ch_layout);
#else
                        m->audio_frame->channel_layout = m->audio_enc_ctx->channel_layout;
                        m->audio_frame->channels = m->audio_channels;
#endif
                        m->audio_frame->sample_rate = m->audio_sample_rate;
                        av_frame_get_buffer(m->audio_frame, 0);

#if LIBAVUTIL_VERSION_INT >= AV_VERSION_INT(57, 28, 100)
                        AVChannelLayout in_ch_layout;
                        av_channel_layout_default(&in_ch_layout, m->audio_channels);
                        swr_alloc_set_opts2(
                            &m->swr_ctx,
                            &m->audio_enc_ctx->ch_layout,
                            m->audio_enc_ctx->sample_fmt,
                            m->audio_sample_rate,
                            &in_ch_layout,
                            AV_SAMPLE_FMT_FLT,
                            m->audio_sample_rate,
                            0, NULL
                        );
#else
                        m->swr_ctx = swr_alloc_set_opts(
                            NULL,
                            m->audio_enc_ctx->channel_layout,
                            m->audio_enc_ctx->sample_fmt,
                            m->audio_sample_rate,
                            av_get_default_channel_layout(m->audio_channels),
                            AV_SAMPLE_FMT_FLT,
                            m->audio_sample_rate,
                            0, NULL
                        );
#endif
                        swr_init(m->swr_ctx);

                        m->audio_buf_capacity = m->audio_frame_size * m->audio_channels * 4;
                        m->audio_buffer = (float *)calloc(m->audio_buf_capacity, sizeof(float));
                    }
                }
            }
        }
    }

    /* Open output file */
    if (!(m->fmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&m->fmt_ctx->pb, filename, AVIO_FLAG_WRITE) < 0) {
            osc_muxer_close(m);
            return -1;
        }
    }

    AVDictionary *opts = NULL;
    av_dict_set(&opts, "movflags", "faststart", 0);
    if (avformat_write_header(m->fmt_ctx, &opts) < 0) {
        av_dict_free(&opts);
        osc_muxer_close(m);
        return -1;
    }
    av_dict_free(&opts);

    m->pkt = av_packet_alloc();
    *out_muxer = m;
    return 0;
}

int osc_muxer_write_video_frame(OscMuxer *m, const uint8_t *rgba, int64_t pts_frame) {
    if (!m || !m->video_enc_ctx || !rgba) return -1;

    if (av_frame_make_writable(m->yuv_frame) < 0) return -1;

    const uint8_t *src_data[4] = { rgba, NULL, NULL, NULL };
    int src_linesize[4] = { m->width * 4, 0, 0, 0 };

    sws_scale(
        m->sws_ctx,
        src_data,
        src_linesize,
        0,
        m->height,
        m->yuv_frame->data,
        m->yuv_frame->linesize
    );

    m->yuv_frame->pts = pts_frame;

    int ret = avcodec_send_frame(m->video_enc_ctx, m->yuv_frame);
    if (ret < 0) return -1;

    while (ret >= 0) {
        ret = avcodec_receive_packet(m->video_enc_ctx, m->pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) return -1;

        av_packet_rescale_ts(m->pkt, m->video_enc_ctx->time_base, m->video_stream->time_base);
        m->pkt->stream_index = m->video_stream->index;
        av_interleaved_write_frame(m->fmt_ctx, m->pkt);
        av_packet_unref(m->pkt);
    }

    return 0;
}

static int muxer_encode_audio_frame(OscMuxer *m, const float *pcm_interleaved, int nb_samples) {
    if (av_frame_make_writable(m->audio_frame) < 0) return -1;

    const uint8_t *in_planes[1] = { (const uint8_t *)pcm_interleaved };
    int converted = swr_convert(
        m->swr_ctx,
        m->audio_frame->data,
        m->audio_frame->nb_samples,
        in_planes,
        nb_samples
    );
    if (converted <= 0) return 0;

    m->audio_frame->nb_samples = converted;
    m->audio_frame->pts = m->next_audio_pts;
    m->next_audio_pts += converted;

    int ret = avcodec_send_frame(m->audio_enc_ctx, m->audio_frame);
    if (ret < 0) return -1;

    while (ret >= 0) {
        ret = avcodec_receive_packet(m->audio_enc_ctx, m->pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) return -1;

        av_packet_rescale_ts(m->pkt, m->audio_enc_ctx->time_base, m->audio_stream->time_base);
        m->pkt->stream_index = m->audio_stream->index;
        av_interleaved_write_frame(m->fmt_ctx, m->pkt);
        av_packet_unref(m->pkt);
    }
    return 0;
}

int osc_muxer_write_audio_samples(OscMuxer *m, const float *pcm_interleaved, int num_samples, int64_t pts_sample) {
    (void)pts_sample;
    if (!m || !m->audio_enc_ctx || !pcm_interleaved || num_samples <= 0) return -1;

    int channels = m->audio_channels;
    int samples_left = num_samples;
    const float *p = pcm_interleaved;

    while (samples_left > 0) {
        int space_samples = m->audio_frame_size - m->audio_buf_count;
        int chunk = samples_left < space_samples ? samples_left : space_samples;

        memcpy(
            m->audio_buffer + (m->audio_buf_count * channels),
            p,
            chunk * channels * sizeof(float)
        );

        m->audio_buf_count += chunk;
        p += chunk * channels;
        samples_left -= chunk;

        if (m->audio_buf_count == m->audio_frame_size) {
            muxer_encode_audio_frame(m, m->audio_buffer, m->audio_frame_size);
            m->audio_buf_count = 0;
        }
    }

    return 0;
}

int osc_muxer_flush(OscMuxer *m) {
    if (!m) return -1;

    /* Flush video */
    if (m->video_enc_ctx) {
        avcodec_send_frame(m->video_enc_ctx, NULL);
        while (1) {
            int ret = avcodec_receive_packet(m->video_enc_ctx, m->pkt);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            av_packet_rescale_ts(m->pkt, m->video_enc_ctx->time_base, m->video_stream->time_base);
            m->pkt->stream_index = m->video_stream->index;
            av_interleaved_write_frame(m->fmt_ctx, m->pkt);
            av_packet_unref(m->pkt);
        }
    }

    /* Flush audio remainder */
    if (m->audio_enc_ctx) {
        if (m->audio_buf_count > 0) {
            /* Zero pad */
            memset(
                m->audio_buffer + (m->audio_buf_count * m->audio_channels),
                0,
                (m->audio_frame_size - m->audio_buf_count) * m->audio_channels * sizeof(float)
            );
            muxer_encode_audio_frame(m, m->audio_buffer, m->audio_frame_size);
            m->audio_buf_count = 0;
        }

        avcodec_send_frame(m->audio_enc_ctx, NULL);
        while (1) {
            int ret = avcodec_receive_packet(m->audio_enc_ctx, m->pkt);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            av_packet_rescale_ts(m->pkt, m->audio_enc_ctx->time_base, m->audio_stream->time_base);
            m->pkt->stream_index = m->audio_stream->index;
            av_interleaved_write_frame(m->fmt_ctx, m->pkt);
            av_packet_unref(m->pkt);
        }
    }

    return 0;
}

int osc_muxer_close(OscMuxer *m) {
    if (!m) return 0;

    osc_muxer_flush(m);

    if (m->fmt_ctx) {
        av_write_trailer(m->fmt_ctx);
    }

    if (m->sws_ctx) {
        sws_freeContext(m->sws_ctx);
        m->sws_ctx = NULL;
    }
    if (m->yuv_frame) {
        av_frame_free(&m->yuv_frame);
        m->yuv_frame = NULL;
    }
    if (m->video_enc_ctx) {
        avcodec_free_context(&m->video_enc_ctx);
        m->video_enc_ctx = NULL;
    }

    if (m->swr_ctx) {
        swr_free(&m->swr_ctx);
        m->swr_ctx = NULL;
    }
    if (m->audio_frame) {
        av_frame_free(&m->audio_frame);
        m->audio_frame = NULL;
    }
    if (m->audio_enc_ctx) {
        avcodec_free_context(&m->audio_enc_ctx);
        m->audio_enc_ctx = NULL;
    }
    if (m->audio_buffer) {
        free(m->audio_buffer);
        m->audio_buffer = NULL;
    }

    if (m->pkt) {
        av_packet_free(&m->pkt);
        m->pkt = NULL;
    }

    if (m->fmt_ctx) {
        if (!(m->fmt_ctx->oformat->flags & AVFMT_NOFILE) && m->fmt_ctx->pb) {
            avio_closep(&m->fmt_ctx->pb);
        }
        avformat_free_context(m->fmt_ctx);
        m->fmt_ctx = NULL;
    }

    free(m);
    return 0;
}

/* ========================================================================= */
/*                              GIF MUXER                                    */
/* ========================================================================= */

struct OscGifMuxer {
    AVFormatContext *fmt_ctx;
    AVStream *stream;
    AVCodecContext *enc_ctx;
    struct SwsContext *sws_ctx;
    AVFrame *frame;
    int width;
    int height;
    int fps_num;
    int fps_den;
    AVPacket *pkt;
};

int osc_gif_muxer_open(const char *filename, int width, int height, int fps_num, int fps_den, OscGifMuxer **out_gif) {
    if (!filename || !out_gif || width <= 0 || height <= 0 || fps_num <= 0 || fps_den <= 0) return -1;
    *out_gif = NULL;

    OscGifMuxer *g = (OscGifMuxer *)calloc(1, sizeof(OscGifMuxer));
    if (!g) return -1;

    g->width = width;
    g->height = height;
    g->fps_num = fps_num;
    g->fps_den = fps_den;

    if (avformat_alloc_output_context2(&g->fmt_ctx, NULL, "gif", filename) < 0 || !g->fmt_ctx) {
        free(g);
        return -1;
    }

    const AVCodec *codec = avcodec_find_encoder(AV_CODEC_ID_GIF);
    if (!codec) {
        avformat_free_context(g->fmt_ctx);
        free(g);
        return -1;
    }

    g->stream = avformat_new_stream(g->fmt_ctx, NULL);
    if (!g->stream) {
        avformat_free_context(g->fmt_ctx);
        free(g);
        return -1;
    }

    g->enc_ctx = avcodec_alloc_context3(codec);
    if (!g->enc_ctx) {
        avformat_free_context(g->fmt_ctx);
        free(g);
        return -1;
    }

    g->enc_ctx->width = width;
    g->enc_ctx->height = height;
    g->enc_ctx->time_base = (AVRational){ fps_den, fps_num };
    g->stream->time_base = (AVRational){ fps_den, fps_num };
    g->enc_ctx->framerate = (AVRational){ fps_num, fps_den };
    g->enc_ctx->pix_fmt = AV_PIX_FMT_RGB8;

    if (avcodec_open2(g->enc_ctx, codec, NULL) < 0) {
        avcodec_free_context(&g->enc_ctx);
        avformat_free_context(g->fmt_ctx);
        free(g);
        return -1;
    }

    avcodec_parameters_from_context(g->stream->codecpar, g->enc_ctx);

    g->frame = av_frame_alloc();
    g->frame->format = g->enc_ctx->pix_fmt;
    g->frame->width = width;
    g->frame->height = height;
    if (av_frame_get_buffer(g->frame, 32) < 0) {
        osc_gif_muxer_close(g);
        return -1;
    }

    g->sws_ctx = sws_getContext(
        width, height, AV_PIX_FMT_RGBA,
        width, height, g->enc_ctx->pix_fmt,
        SWS_BILINEAR, NULL, NULL, NULL
    );

    if (!(g->fmt_ctx->oformat->flags & AVFMT_NOFILE)) {
        if (avio_open(&g->fmt_ctx->pb, filename, AVIO_FLAG_WRITE) < 0) {
            osc_gif_muxer_close(g);
            return -1;
        }
    }

    if (avformat_write_header(g->fmt_ctx, NULL) < 0) {
        osc_gif_muxer_close(g);
        return -1;
    }

    g->pkt = av_packet_alloc();
    *out_gif = g;
    return 0;
}

int osc_gif_muxer_write_frame(OscGifMuxer *g, const uint8_t *rgba, int64_t pts_frame) {
    if (!g || !g->enc_ctx || !rgba) return -1;

    if (av_frame_make_writable(g->frame) < 0) return -1;

    const uint8_t *src_data[4] = { rgba, NULL, NULL, NULL };
    int src_linesize[4] = { g->width * 4, 0, 0, 0 };

    sws_scale(
        g->sws_ctx,
        src_data,
        src_linesize,
        0,
        g->height,
        g->frame->data,
        g->frame->linesize
    );

    g->frame->pts = pts_frame;

    int ret = avcodec_send_frame(g->enc_ctx, g->frame);
    if (ret < 0) return -1;

    while (ret >= 0) {
        ret = avcodec_receive_packet(g->enc_ctx, g->pkt);
        if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
        if (ret < 0) return -1;

        av_packet_rescale_ts(g->pkt, g->enc_ctx->time_base, g->stream->time_base);
        g->pkt->stream_index = g->stream->index;
        av_interleaved_write_frame(g->fmt_ctx, g->pkt);
        av_packet_unref(g->pkt);
    }

    return 0;
}

int osc_gif_muxer_close(OscGifMuxer *g) {
    if (!g) return 0;

    if (g->enc_ctx) {
        avcodec_send_frame(g->enc_ctx, NULL);
        while (1) {
            int ret = avcodec_receive_packet(g->enc_ctx, g->pkt);
            if (ret == AVERROR(EAGAIN) || ret == AVERROR_EOF) break;
            if (ret < 0) break;

            av_packet_rescale_ts(g->pkt, g->enc_ctx->time_base, g->stream->time_base);
            g->pkt->stream_index = g->stream->index;
            av_interleaved_write_frame(g->fmt_ctx, g->pkt);
            av_packet_unref(g->pkt);
        }
    }

    if (g->fmt_ctx) {
        av_write_trailer(g->fmt_ctx);
    }

    if (g->sws_ctx) {
        sws_freeContext(g->sws_ctx);
        g->sws_ctx = NULL;
    }
    if (g->frame) {
        av_frame_free(&g->frame);
        g->frame = NULL;
    }
    if (g->enc_ctx) {
        avcodec_free_context(&g->enc_ctx);
        g->enc_ctx = NULL;
    }
    if (g->pkt) {
        av_packet_free(&g->pkt);
        g->pkt = NULL;
    }
    if (g->fmt_ctx) {
        if (!(g->fmt_ctx->oformat->flags & AVFMT_NOFILE) && g->fmt_ctx->pb) {
            avio_closep(&g->fmt_ctx->pb);
        }
        avformat_free_context(g->fmt_ctx);
        g->fmt_ctx = NULL;
    }
    free(g);
    return 0;
}
