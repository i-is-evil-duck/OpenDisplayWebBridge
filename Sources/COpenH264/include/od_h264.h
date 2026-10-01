// od_h264.h — a small, stable C surface over OpenH264's H.264 decoder.
//
// Why this exists
// ---------------
// The bridge is a relay. To feed an old iPad (no WebCodecs, no MSE) it has to
// decode the sender's H.264 and re-encode as VP8 for WebRTC.
//
// VideoToolbox is the natural decoder and is hardware-accelerated, but macOS
// gates the hardware media path behind a real Developer ID signature. This
// process is unsigned, so `VTDecompressionSessionDecodeFrame` returns noErr and
// the output callback never fires — no error, just silence. OpenH264 is a
// software decoder that is not gated, so it is the fallback that makes the
// WebRTC path work at all without a paid Apple Developer account.
//
// Why a C shim rather than calling OpenH264 from Swift
// ---------------------------------------------------
// OpenH264 2.6's public API is the C++ `ISVCDecoder` virtual interface, and the
// legacy C entry point (`WelsDecodeBs`) needs an `SDecoderParam` struct that
// Homebrew does not ship. Re-declaring those structs in Swift would mean
// hand-maintaining a layout match against a C++ header — the kind of thing that
// compiles cleanly and then corrupts memory. Wrapping them in C++ lets the real
// headers define the layout, and gives Swift a five-function C API.

#ifndef OD_H264_H
#define OD_H264_H

#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct OdH264Decoder OdH264Decoder;

/// One decoded frame in I420. The three plane pointers reference
/// decoder-owned memory and are only valid until the next `od_h264_decode` on
/// the same handle, so the caller must copy before decoding again.
typedef struct {
  /// OpenH264 `DECODING_STATE` for the NAL that produced this frame.
  /// `0` (`dsErrorFree`) is what a healthy decode returns.
  int32_t state;
  int32_t width;
  int32_t height;
  /// Stride in bytes of the Y plane, and of each of the U and V planes.
  int32_t yStride;
  int32_t uvStride;
  const uint8_t *y;
  const uint8_t *u;
  const uint8_t *v;
} OdH264Frame;

/// Creates a decoder, or returns NULL. The OpenH264 API reports failure as a
/// non-zero `long` from `Initialize`, and callers need to distinguish "could
/// not create" from "decoded nothing", hence a NULL handle.
OdH264Decoder *od_h264_create(void);

void od_h264_destroy(OdH264Decoder *decoder);

/// Discards all decoder state while keeping the handle valid, so the next
/// access unit must be a keyframe.
///
/// This is a reset, NOT a destroy. `od_h264_destroy` frees the handle, so
/// calling it and expecting the handle to keep working is a use-after-free, and
/// pairing it with a later `od_h264_destroy` is a double free. Callers that need
/// to drop reference pictures must use this.
///
/// Idempotent: safe on a fresh handle, and safe to call repeatedly. Returns 0 on
/// success, negative if the decoder could not be re-initialised (in which case
/// the handle is still valid but will not decode).
int32_t od_h264_reset(OdH264Decoder *decoder);

/// Decodes one Annex-B access unit (start codes included, any number of NALs).
///
/// Returns 0 when the call itself succeeded, negative when arguments were bad.
/// That is deliberately *not* the decode outcome: parameter-set NALs and
/// non-reference frames legitimately produce no picture, so "did I get a frame"
/// is answered by `out->y != NULL` on return, and failures are reported through
/// `out->state`. Collapsing those into one return value is what made a previous
/// attempt undebuggable.
///
/// The handle is not internally synchronised; the caller owns it.
int32_t od_h264_decode(OdH264Decoder *decoder, const uint8_t *data, int32_t length,
                       OdH264Frame *out);

/// OpenH264's version string, for logging. Never NULL.
const char *od_h264_version(void);

#ifdef __cplusplus
}  // extern "C"
#endif

#endif  // OD_H264_H
