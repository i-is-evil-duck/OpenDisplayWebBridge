// od_h264_enc.h — a small, stable C surface over OpenH264's H.264 *encoder*.
//
// Why this exists
// ---------------
// The decoder in od_h264.h is what makes the product work. The encoder is test
// and demo scaffolding, and it is here for one concrete reason: everything else
// on this Mac is a dead end for producing H.264.
//
//   * VideoToolbox encode returns kVTParameterErr (-12902) for this unsigned
//     process, so the bridge's own DemoSender cannot generate video either.
//   * There is no ffmpeg installed, and adding one as a test dependency would be
//     a far larger commitment than the codec itself.
//
// OpenH264 is already linked, is BSD-2-Clause, and ships an encoder in the same
// dylib. That makes "produce a real H.264 stream" a dozen lines instead of a new
// dependency, and it is ungated by TCC the same way the decoder is.
//
// What it buys:
//   * A committed fixture that the decoder tests can replay offline. Synthetic
//     NALs prove the demuxer works but cannot prove a decoder works.
//   * A moving test pattern, which is the only way to exercise the continuous
//     decode -> VP8 -> browser path. A static screen makes the sender replay one
//     frame forever (PROTOCOL.md 5.3), so a live capture never produces the
//     stream a moving source does.
//
// This is not on the product's hot path. If the OpenH264 encoder is ever removed
// upstream, only the tests and the synthetic demo mode break.

#ifndef OD_H264_ENC_H
#define OD_H264_ENC_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OdH264Encoder OdH264Encoder;

/// Creates an encoder, or returns NULL. `width` and `height must be even (H.264
/// 4:2:0 chroma subsampling), which is not checked here because a bad geometry
/// shows up as a NULL handle rather than as corrupt output.
OdH264Encoder *od_h264_encoder_create(int32_t width, int32_t height,
                                      int32_t fps, int32_t bitrate);

void od_h264_encoder_destroy(OdH264Encoder *encoder);

/// Upper bound on `outCapacity` for a single frame, so the caller can size a
/// buffer once. One raw I420 frame plus generous per-NAL start-code and
/// emulation-prevention overhead.
int32_t od_h264_encoder_max_bytes(int32_t width, int32_t height);

/// Encodes one I420 frame and writes a complete Annex-B access unit (SPS, PPS
/// and slice, each behind a 4-byte start code) into `out`.
///
/// Returns the number of bytes written, 0 if the encoder had nothing to emit
/// (possible with rate control), or negative on failure. `outKeyframe`, when
/// non-NULL, receives 1 for an IDR.
int32_t od_h264_encoder_encode(OdH264Encoder *encoder,
                               const uint8_t *y, int32_t yStride,
                               const uint8_t *u, int32_t uStride,
                               const uint8_t *v, int32_t vStride,
                               int32_t width, int32_t height,
                               uint8_t *out, int32_t outCapacity,
                               int32_t *outKeyframe);

/// Forces the next frame to be an IDR. Needed after the decoder is created
/// mid-stream, or after a parameter-set change, to guarantee it can start.
void od_h264_encoder_force_keyframe(OdH264Encoder *encoder);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // OD_H264_ENC_H
