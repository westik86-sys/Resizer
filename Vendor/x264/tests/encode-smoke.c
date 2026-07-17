/*
 * Real libx264 encode smoke for the Resizer reproducible toolchain.
 *
 * This exercises every planar chroma family supported by the pinned
 * --bit-depth=all/--chroma-format=all build at both 8 and 10 bits. It writes
 * no media files; success requires each encoder instance to emit a non-empty
 * Annex B bitstream in memory.
 */

#include <stdint.h>
#include <stdio.h>
#include <string.h>

#include <x264.h>

enum
{
    smoke_width = 64,
    smoke_height = 64,
    smoke_frame_count = 4,
};

typedef struct
{
    int csp;
    const char *name;
} smoke_format_t;

static int plane_height( int csp, int plane )
{
    if( plane == 0 || csp != X264_CSP_I420 )
        return smoke_height;
    return smoke_height / 2;
}

static void fill_picture( x264_picture_t *picture, int csp, int bitdepth, int frame )
{
    for( int plane = 0; plane < picture->img.i_plane; plane++ )
    {
        const int height = plane_height( csp, plane );
        const int stride = picture->img.i_stride[plane];

        for( int y = 0; y < height; y++ )
        {
            if( bitdepth == 8 )
            {
                const uint8_t value = plane == 0
                    ? (uint8_t)(32 + ((frame * 17 + y) % 192))
                    : (uint8_t)(112 + plane * 16);
                memset( picture->img.plane[plane] + y * stride, value, (size_t)stride );
            }
            else
            {
                uint16_t *row = (uint16_t *)(picture->img.plane[plane] + y * stride);
                const int samples = stride / (int)sizeof(*row);
                const uint16_t value = plane == 0
                    ? (uint16_t)(128 + ((frame * 67 + y * 3) % 768))
                    : (uint16_t)(448 + plane * 64);

                for( int x = 0; x < samples; x++ )
                    row[x] = value;
            }
        }
    }
}

static int encode_format( const smoke_format_t *format, int bitdepth )
{
    x264_param_t param;
    x264_picture_t input;
    x264_picture_t output;
    x264_t *encoder = NULL;
    int picture_allocated = 0;
    int64_t encoded_bytes = 0;

    if( x264_param_default_preset( &param, "medium", NULL ) < 0 )
    {
        fprintf( stderr, "%d-bit %s: parameter initialization failed\n", bitdepth, format->name );
        return 1;
    }

    param.i_bitdepth = bitdepth;
    param.i_csp = format->csp;
    param.i_width = smoke_width;
    param.i_height = smoke_height;
    param.i_fps_num = 24;
    param.i_fps_den = 1;
    param.i_timebase_num = 1;
    param.i_timebase_den = 24;
    param.i_frame_total = smoke_frame_count;
    param.b_vfr_input = 0;
    param.b_repeat_headers = 1;
    param.b_annexb = 1;
    param.i_threads = 1;
    param.i_log_level = X264_LOG_ERROR;
    param.rc.i_rc_method = X264_RC_CRF;
    param.rc.f_rf_constant = 22.0f;

    const int input_csp = format->csp |
        (bitdepth == 10 ? X264_CSP_HIGH_DEPTH : 0);
    if( x264_picture_alloc( &input, input_csp, smoke_width, smoke_height ) < 0 )
        goto fail;
    picture_allocated = 1;

    encoder = x264_encoder_open( &param );
    if( !encoder )
        goto fail;

    for( int frame = 0; frame < smoke_frame_count; frame++ )
    {
        x264_nal_t *nals = NULL;
        int nal_count = 0;
        fill_picture( &input, format->csp, bitdepth, frame );
        input.i_pts = frame;

        const int frame_bytes = x264_encoder_encode(
            encoder,
            &nals,
            &nal_count,
            &input,
            &output
        );
        if( frame_bytes < 0 || (frame_bytes > 0 && (!nals || nal_count <= 0)) )
            goto fail;
        encoded_bytes += frame_bytes;
    }

    while( x264_encoder_delayed_frames( encoder ) )
    {
        x264_nal_t *nals = NULL;
        int nal_count = 0;
        const int frame_bytes = x264_encoder_encode(
            encoder,
            &nals,
            &nal_count,
            NULL,
            &output
        );
        if( frame_bytes < 0 || (frame_bytes > 0 && (!nals || nal_count <= 0)) )
            goto fail;
        encoded_bytes += frame_bytes;
    }

    if( encoded_bytes <= 0 )
        goto fail;

    x264_encoder_close( encoder );
    x264_picture_clean( &input );
    x264_param_cleanup( &param );
    printf( "%d-bit %s: ok\n", bitdepth, format->name );
    return 0;

fail:
    if( encoder )
        x264_encoder_close( encoder );
    if( picture_allocated )
        x264_picture_clean( &input );
    x264_param_cleanup( &param );
    fprintf( stderr, "%d-bit %s: encode failed\n", bitdepth, format->name );
    return 1;
}

int main( void )
{
    static const smoke_format_t formats[] = {
        { X264_CSP_I400, "4:0:0" },
        { X264_CSP_I420, "4:2:0" },
        { X264_CSP_I422, "4:2:2" },
        { X264_CSP_I444, "4:4:4" },
    };
    static const int bitdepths[] = { 8, 10 };

    for( size_t depth = 0; depth < sizeof(bitdepths) / sizeof(bitdepths[0]); depth++ )
        for( size_t format = 0; format < sizeof(formats) / sizeof(formats[0]); format++ )
            if( encode_format( &formats[format], bitdepths[depth] ) != 0 )
                return 1;

    return 0;
}
