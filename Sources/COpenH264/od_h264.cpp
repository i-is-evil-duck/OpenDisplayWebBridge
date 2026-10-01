#include "od_h264.h"

#include "wels/codec_api.h"
#include "wels/codec_app_def.h"
#include "wels/codec_ver.h"

#include <cstring>

namespace {

// Wraps OpenH264's C++ interface so the C entry points stay trivial. `decoder`
// is null once `od_h264_destroy` has run.
//
// Deliberately *not* named OdH264Decoder: in C++ a class name is injected into
// its enclosing scope, so `struct OdH264Decoder` would clash with the typedef of
// the same name in od_h264.h and make every signature ambiguous.
struct DecoderImpl {
  ISVCDecoder *decoder = nullptr;
};

/// Fills the decode parameters. Shared by `od_h264_create` and `od_h264_reset`
/// so a reset reproduces exactly the configuration the decoder was created with
/// — re-initialising with different parameters would make a reset silently
/// change decoder behaviour rather than only dropping its state.
void FillDecodingParam(SDecodingParam *param) {
  std::memset(param, 0, sizeof(*param));
  // 255 selects the highest layer: no spatial downscaling, so the browser gets
  // the sender's full resolution.
  param->uiTargetDqLayer = 255;
  // Copy the previous frame on a broken reference rather than emitting
  // concealment garbage: a stale-but-correct picture beats a green screen.
  param->eEcActiveIdc = ERROR_CON_FRAME_COPY;
  param->bParseOnly = false;
  param->sVideoProperty.size = sizeof(param->sVideoProperty);
  param->sVideoProperty.eVideoBsType = VIDEO_BITSTREAM_AVC;
}

}  // namespace

extern "C" {

OdH264Decoder *od_h264_create(void) {
  ISVCDecoder *decoder = nullptr;
  if (WelsCreateDecoder(&decoder) != 0 || decoder == nullptr) return nullptr;

  SDecodingParam param;
  FillDecodingParam(&param);

  if (decoder->Initialize(&param) != 0) {
    WelsDestroyDecoder(decoder);
    return nullptr;
  }

  auto *handle = new DecoderImpl();
  handle->decoder = decoder;
  return reinterpret_cast<OdH264Decoder *>(handle);
}

void od_h264_destroy(OdH264Decoder *handle) {
  if (handle == nullptr) return;
  auto *impl = reinterpret_cast<DecoderImpl *>(handle);
  if (impl->decoder != nullptr) {
    impl->decoder->Uninitialize();
    WelsDestroyDecoder(impl->decoder);
    impl->decoder = nullptr;
  }
  delete impl;
}

int32_t od_h264_reset(OdH264Decoder *handle) {
  if (handle == nullptr) return -1;
  auto *impl = reinterpret_cast<DecoderImpl *>(handle);
  if (impl->decoder == nullptr) return -1;

  // Uninitialize + Initialize on the SAME instance. This is OpenH264's reset
  // idiom: it drops every reference picture and the parameter-set cache while
  // keeping the handle — and therefore the caller's pointer — valid.
  //
  // The alternative, destroying the decoder and creating a replacement, is what
  // this function exists to make unnecessary: it leaves the caller's handle
  // dangling, so the next decode is a use-after-free and the final destroy is a
  // double free.
  impl->decoder->Uninitialize();

  SDecodingParam param;
  FillDecodingParam(&param);
  return impl->decoder->Initialize(&param) == 0 ? 0 : -1;
}

int32_t od_h264_decode(OdH264Decoder *handle, const uint8_t *data, int32_t length,
                       OdH264Frame *out) {
  if (handle == nullptr) return -1;
  auto *impl = reinterpret_cast<DecoderImpl *>(handle);
  if (impl->decoder == nullptr) return -1;
  if (data == nullptr || length <= 0 || out == nullptr) return -1;

  std::memset(out, 0, sizeof(*out));

  // The whole Annex-B access unit goes in one call, start codes included.
  //
  // Splitting it into NALs and calling once per NAL — which is what OpenH264's
  // older C API examples do, and what the first version of this file did —
  // returns dsBitstreamError for a stream this decoder then refuses to produce
  // any picture from. That is a silent failure with no other symptom, so it is
  // worth stating plainly rather than leaving as a comment on a loop.
  SBufferInfo info;
  std::memset(&info, 0, sizeof(info));
  const DECODING_STATE state =
      impl->decoder->DecodeFrameNoDelay(data, length, info.pDst, &info);

  out->state = static_cast<int32_t>(state);

  // iBufferStatus 0 means "no picture ready". That is normal for an access unit
  // carrying only parameter sets, and for non-reference frames — not an error.
  if (info.iBufferStatus != 1) return 0;
  if (info.pDst[0] == nullptr || info.pDst[1] == nullptr || info.pDst[2] == nullptr) {
    return 0;
  }

  const SSysMEMBuffer &mem = info.UsrData.sSystemBuffer;
  if (mem.iWidth <= 0 || mem.iHeight <= 0) return 0;

  out->width = mem.iWidth;
  out->height = mem.iHeight;
  out->yStride = mem.iStride[0];
  out->uvStride = mem.iStride[1];
  out->y = info.pDst[0];
  out->u = info.pDst[1];
  out->v = info.pDst[2];
  return 0;
}

const char *od_h264_version(void) {
  // `WelsGetCodecVersionEx` fills a struct of four unsigned ints with no
  // string, so the header's own version string is the readable option. It is
  // `static const` per translation unit, which is harmless here.
  return g_strCodecVer;
}

}  // extern "C"
