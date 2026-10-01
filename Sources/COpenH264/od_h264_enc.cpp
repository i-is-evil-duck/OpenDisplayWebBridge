#include "od_h264_enc.h"

#include "wels/codec_api.h"
#include "wels/codec_app_def.h"

#include <cstring>

namespace {

// Not named OdH264Encoder: in C++ a class name lands in the enclosing scope, so
// it would collide with the typedef of the same name in od_h264_enc.h.
struct EncoderImpl {
  ISVCEncoder *encoder = nullptr;
  int32_t width = 0;
  int32_t height = 0;
};

// True if the NAL already carries a leading 3- or 4-byte start code.
bool hasStartCode(const unsigned char *nalu, int32_t length) {
  if (length >= 4 && nalu[0] == 0 && nalu[1] == 0 && nalu[2] == 0 && nalu[3] == 1) return true;
  if (length >= 3 && nalu[0] == 0 && nalu[1] == 0 && nalu[2] == 1) return true;
  return false;
}

}  // namespace

extern "C" {

OdH264Encoder *od_h264_encoder_create(int32_t width, int32_t height,
                                      int32_t fps, int32_t bitrate) {
  if (width <= 0 || height <= 0 || (width % 2) != 0 || (height % 2) != 0) return nullptr;
  if (fps <= 0) fps = 30;
  if (bitrate <= 0) bitrate = 2000000;

  ISVCEncoder *encoder = nullptr;
  if (WelsCreateSVCEncoder(&encoder) != 0 || encoder == nullptr) return nullptr;

  SEncParamExt param;
  std::memset(&param, 0, sizeof(param));
  if (encoder->GetDefaultParams(&param) != 0) {
    WelsDestroySVCEncoder(encoder);
    return nullptr;
  }

  // Screen content, not camera: the thing being encoded is a desktop, which is
  // flat colour and sharp text. OpenH264 tunes its rate control and deblocking
  // differently for the two, and picking the wrong one visibly wrecks text.
  param.iUsageType = SCREEN_CONTENT_REAL_TIME;
  param.iPicWidth = width;
  param.iPicHeight = height;
  param.iTargetBitrate = bitrate;
  param.iRCMode = RC_BITRATE_MODE;
  param.fMaxFrameRate = static_cast<float>(fps);
  param.uiIntraPeriod = fps * 2;  // a keyframe twice a second, so a late joiner
                                  // recovers in well under a second
  param.bEnableFrameSkip = false;  // a skipped frame is a frozen picture, which
                                   // is the one artefact a test must not have
  param.bEnableSSEI = false;
  param.bPrefixNalAddingCtrl = false;  // Annex B start codes are added below
  param.eSpsPpsIdStrategy = CONSTANT_ID;
  param.iTemporalLayerNum = 1;
  param.iSpatialLayerNum = 1;
  param.iMultipleThreadIdc = 1;  // single-threaded: the caller owns the handle,
                                 // and tests are not throughput-bound
  param.iEntropyCodingModeFlag = 0;  // CAVLC. CABAC is a licence-encumbered part
                                     // of the H.264 standard that Cisco's
                                     // openh264 build omits, so asking for it
                                     // risks a black picture.

  SSpatialLayerConfig &layer = param.sSpatialLayers[0];
  std::memset(&layer, 0, sizeof(layer));
  layer.iVideoWidth = width;
  layer.iVideoHeight = height;
  layer.fFrameRate = static_cast<float>(fps);
  layer.iSpatialBitrate = bitrate;
  layer.iMaxSpatialBitrate = bitrate;
  layer.uiProfileIdc = PRO_UNKNOWN;  // let the encoder choose from the geometry
  layer.uiLevelIdc = LEVEL_UNKNOWN;
  layer.iDLayerQp = 26;
  // Full-range BT.709. Screen pixels are 0-255 with no 16-235 studio range, and
  // getting this wrong is a washed-out or crushed picture that looks like a
  // decode bug when it is not one.
  layer.bVideoSignalTypePresent = true;
  layer.uiVideoFormat = VF_UNDEF;
  layer.bFullRange = true;
  layer.bColorDescriptionPresent = true;
  layer.uiColorPrimaries = CP_BT709;
  layer.uiTransferCharacteristics = TRC_BT709;
  layer.uiColorMatrix = CM_BT709;

  if (encoder->InitializeExt(&param) != 0) {
    WelsDestroySVCEncoder(encoder);
    return nullptr;
  }

  auto *impl = new EncoderImpl();
  impl->encoder = encoder;
  impl->width = width;
  impl->height = height;
  return reinterpret_cast<OdH264Encoder *>(impl);
}

void od_h264_encoder_destroy(OdH264Encoder *handle) {
  if (handle == nullptr) return;
  auto *impl = reinterpret_cast<EncoderImpl *>(handle);
  if (impl->encoder != nullptr) {
    impl->encoder->Uninitialize();
    WelsDestroySVCEncoder(impl->encoder);
    impl->encoder = nullptr;
  }
  delete impl;
}

int32_t od_h264_encoder_max_bytes(int32_t width, int32_t height) {
  // One raw frame, plus room for start codes and emulation-prevention bytes,
  // which can inflate a NAL by a few percent in the worst case.
  return width * height * 3 / 2 + 64 * 1024;
}

int32_t od_h264_encoder_encode(OdH264Encoder *handle,
                               const uint8_t *y, int32_t yStride,
                               const uint8_t *u, int32_t uStride,
                               const uint8_t *v, int32_t vStride,
                               int32_t width, int32_t height,
                               uint8_t *out, int32_t outCapacity,
                               int32_t *outKeyframe) {
  if (handle == nullptr) return -1;
  auto *impl = reinterpret_cast<EncoderImpl *>(handle);
  if (impl->encoder == nullptr || out == nullptr || outCapacity <= 0) return -1;
  if (y == nullptr || u == nullptr || v == nullptr) return -1;
  if (width != impl->width || height != impl->height) return -1;

  SSourcePicture picture;
  std::memset(&picture, 0, sizeof(picture));
  picture.iColorFormat = videoFormatI420;
  picture.iPicWidth = width;
  picture.iPicHeight = height;
  picture.iStride[0] = yStride;
  picture.iStride[1] = uStride;
  picture.iStride[2] = vStride;
  picture.pData[0] = const_cast<uint8_t *>(y);
  picture.pData[1] = const_cast<uint8_t *>(u);
  picture.pData[2] = const_cast<uint8_t *>(v);

  SFrameBSInfo info;
  std::memset(&info, 0, sizeof(info));
  if (impl->encoder->EncodeFrame(&picture, &info) != 0) return -1;

  int32_t written = 0;
  for (int32_t i = 0; i < info.iLayerNum; ++i) {
    const SLayerBSInfo &layer = info.sLayerInfo[i];
    if (layer.iNalCount <= 0 || layer.pBsBuf == nullptr) continue;
    int32_t offset = 0;
    for (int32_t n = 0; n < layer.iNalCount; ++n) {
      const int32_t length = layer.pNalLengthInByte[n];
      if (length <= 0) continue;
      const unsigned char *nalu = layer.pBsBuf + offset;
      offset += length;

      // OpenH264 2.6 already writes each NAL into pBsBuf behind a start code,
      // even with bPrefixNalAddingCtrl false. Emitting another one here yields
      // "00 00 00 01 00 00 00 01 <nal>", and the decoder rejects that as a
      // bitstream error with no other symptom. So only add a start code when
      // there is not already one — which also keeps this correct if a future
      // version changes the convention.
      int32_t payload = length;
      int32_t header = hasStartCode(nalu, length) ? 0 : 4;
      // 4 bytes of start code plus the NAL, and the caller sized the buffer with
      // headroom, but checking keeps a truncated write from corrupting memory.
      if (written + header + payload > outCapacity) return -1;
      for (int32_t b = 0; b < header; ++b) out[written + b] = 0;
      if (header == 4) out[written + 3] = 1;
      std::memcpy(out + written + header, nalu, static_cast<size_t>(payload));
      written += header + payload;
    }
  }

  if (outKeyframe != nullptr) {
    *outKeyframe = (info.eFrameType == videoFrameTypeIDR) ? 1 : 0;
  }
  return written;
}

void od_h264_encoder_force_keyframe(OdH264Encoder *handle) {
  if (handle == nullptr) return;
  auto *impl = reinterpret_cast<EncoderImpl *>(handle);
  if (impl->encoder != nullptr) impl->encoder->ForceIntraFrame(true);
}

}  // extern "C"
