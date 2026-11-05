#include "napi/native_api.h"
#include <hilog/log.h>
#include <multimedia/player_framework/native_avscreen_capture.h>
#include <multimedia/player_framework/native_avcodec_videoencoder.h>
#include <multimedia/player_framework/native_avformat.h>
#include <multimedia/player_framework/native_avbuffer.h>
#include <native_window/external_window.h>
#include <sys/socket.h>
#include <sys/time.h>
#include <arpa/inet.h>
#include <unistd.h>
#include <atomic>
#include <thread>
#include <mutex>
#include <vector>
#include <string>
#include <chrono>
#include <cstring>

namespace {
constexpr int kDefaultVideoFPS = 60;
OH_AVCodec* encoder = nullptr;
OH_AVScreenCapture* capture = nullptr;
OHNativeWindow* surface = nullptr;
std::atomic<bool> running{false};
std::atomic<int> state{-1}, lastError{0}, stage{0};
std::atomic<uint64_t> frames{0}, totalBytes{0};
int listener = -1, client = -1;
bool needsHeader = true;
std::mutex socketMutex;
std::thread acceptThread;
std::vector<uint8_t> codecHeader;
std::vector<uint8_t> latestKeyframe;
int64_t latestKeyframePTS = 0;
std::string secret;

bool SendAll(int fd, const uint8_t* data, size_t count) {
    while (count) {
        ssize_t written = send(fd, data, count, MSG_NOSIGNAL);
        if (written <= 0) return false;
        data += written; count -= written;
    }
    return true;
}
bool Packet(const uint8_t* data, uint32_t count, uint32_t flags, int64_t pts) {
    uint8_t header[16];
    uint32_t sizeBE = htonl(count), flagsBE = htonl(flags);
    memcpy(header, &sizeBE, 4); memcpy(header+4, &flagsBE, 4);
    uint64_t value = static_cast<uint64_t>(pts);
    for (int i=0;i<8;i++) header[8+i] = (value >> (56-i*8)) & 255;
    return SendAll(client, header, sizeof(header)) && SendAll(client, data, count);
}
void EncError(OH_AVCodec*, int32_t error, void*) { lastError = error; }
void Changed(OH_AVCodec*, OH_AVFormat*, void*) {}
void Input(OH_AVCodec*, uint32_t, OH_AVBuffer*, void*) {}
void Output(OH_AVCodec* codec, uint32_t index, OH_AVBuffer* buffer, void*) {
    OH_AVCodecBufferAttr attr{};
    auto* bytes = OH_AVBuffer_GetAddr(buffer);
    if (OH_AVBuffer_GetBufferAttr(buffer, &attr) == AV_ERR_OK && bytes && attr.size > 0) {
        const uint8_t* data = bytes + attr.offset;
        bool config = attr.flags & AVCODEC_BUFFER_FLAGS_CODEC_DATA;
        if (!config) frames++;
        totalBytes += attr.size;
        std::lock_guard<std::mutex> guard(socketMutex);
        if (config) codecHeader.assign(data, data + attr.size);
        if (attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) {
            latestKeyframe.assign(data, data + attr.size);
            latestKeyframePTS = attr.pts;
        }
        if (client >= 0) {
            bool good = true;
            if (needsHeader && !config) {
                if (!(attr.flags & AVCODEC_BUFFER_FLAGS_SYNC_FRAME) || codecHeader.empty()) {
                    OH_VideoEncoder_FreeOutputBuffer(codec, index); return;
                }
                good = Packet(codecHeader.data(), codecHeader.size(), AVCODEC_BUFFER_FLAGS_CODEC_DATA, attr.pts);
                needsHeader = false;
            }
            if (good) good = Packet(data, attr.size, attr.flags, attr.pts);
            if (config) needsHeader = false;
            if (!good) { shutdown(client, SHUT_RDWR); close(client); client = -1; }
        }
    }
    OH_VideoEncoder_FreeOutputBuffer(codec, index);
}
void CaptureState(OH_AVScreenCapture* instance, OH_AVScreenCaptureStateCode code, void*) {
    state = static_cast<int>(code);
    if (code == OH_SCREEN_CAPTURE_STATE_STARTED) {
        int result = OH_AVScreenCapture_SetMaxVideoFrameRate(instance, kDefaultVideoFPS);
        if (result) lastError = result;
        OH_LOG_Print(LOG_APP, LOG_INFO, 0x1234, "HBridge", "Capture started; set 60 FPS result=%{public}d", result);
    }
}
void CaptureError(OH_AVScreenCapture*, int32_t error, void*) { lastError = error; }

void Stop() {
    running = false;
    if (listener >= 0) { shutdown(listener, SHUT_RDWR); close(listener); listener = -1; }
    { std::lock_guard<std::mutex> guard(socketMutex); if (client >= 0) { shutdown(client, SHUT_RDWR); close(client); client = -1; } }
    if (acceptThread.joinable()) acceptThread.join();
    if (capture) { OH_AVScreenCapture_StopScreenCapture(capture); OH_AVScreenCapture_Release(capture); capture = nullptr; }
    if (encoder) { OH_VideoEncoder_Stop(encoder); OH_VideoEncoder_Destroy(encoder); encoder = nullptr; }
    if (surface) { OH_NativeWindow_DestroyNativeWindow(surface); surface = nullptr; }
    codecHeader.clear(); latestKeyframe.clear(); state = -1;
}

int Start(const std::string& token) {
    Stop(); secret = token; frames = 0; totalBytes = 0; lastError = 0; state = -1;
    stage = 1;
    encoder = OH_VideoEncoder_CreateByMime("video/avc");
    if (!encoder) return -100;
    OH_AVCodecCallback callbacks{EncError, Changed, Input, Output};
    stage = 2;
    int result = OH_VideoEncoder_RegisterCallback(encoder, callbacks, nullptr);
    if (result) return result;
    OH_AVFormat* format = OH_AVFormat_Create();
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_WIDTH, 720);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_HEIGHT, 1552);
    OH_AVFormat_SetDoubleValue(format, OH_MD_KEY_FRAME_RATE, static_cast<double>(kDefaultVideoFPS));
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PIXEL_FORMAT, AV_PIXEL_FORMAT_SURFACE_FORMAT);
    OH_AVFormat_SetLongValue(format, OH_MD_KEY_BITRATE, 12000000);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_I_FRAME_INTERVAL, 1000);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_PROFILE, AVC_PROFILE_BASELINE);
    OH_AVFormat_SetIntValue(format, OH_MD_KEY_VIDEO_ENABLE_LOW_LATENCY, 1);
    stage = 3;
    result = OH_VideoEncoder_Configure(encoder, format);
    OH_AVFormat_Destroy(format);
    if (result) return result;
    stage = 4;
    if ((result = OH_VideoEncoder_GetSurface(encoder, &surface))) return result;
    stage = 5;
    if ((result = OH_VideoEncoder_Prepare(encoder))) return result;
    stage = 6;
    if ((result = OH_VideoEncoder_Start(encoder))) return result;
    stage = 7;
    capture = OH_AVScreenCapture_Create();
    if (!capture) return -101;
    OH_AVScreenCapture_SetStateCallback(capture, CaptureState, nullptr);
    OH_AVScreenCapture_SetErrorCallback(capture, CaptureError, nullptr);
    OH_AVScreenCapture_SetMicrophoneEnabled(capture, false);
    OH_AVScreenCaptureConfig config{};
    config.captureMode = OH_CAPTURE_HOME_SCREEN;
    config.dataType = OH_ORIGINAL_STREAM;
    config.videoInfo.videoCapInfo.videoFrameWidth = 720;
    config.videoInfo.videoCapInfo.videoFrameHeight = 1552;
    config.videoInfo.videoCapInfo.videoSource = OH_VIDEO_SOURCE_SURFACE_RGBA;
    stage = 8;
    if ((result = OH_AVScreenCapture_Init(capture, config))) return result;
    stage = 10;
    listener = socket(AF_INET, SOCK_STREAM, 0);
    int reuse = 1; setsockopt(listener, SOL_SOCKET, SO_REUSEADDR, &reuse, sizeof(reuse));
    sockaddr_in address{}; address.sin_family = AF_INET; address.sin_port = htons(28766); address.sin_addr.s_addr = htonl(INADDR_LOOPBACK);
    if (bind(listener, reinterpret_cast<sockaddr*>(&address), sizeof(address)) || listen(listener, 2)) return -102;
    running = true;
    acceptThread = std::thread([] {
        while (running) {
            int connection = accept(listener, nullptr, nullptr);
            if (connection < 0) break;
            timeval receiveTimeout{3,0}, sendTimeout{0,250000};
            setsockopt(connection, SOL_SOCKET, SO_RCVTIMEO, &receiveTimeout, sizeof(receiveTimeout));
            setsockopt(connection, SOL_SOCKET, SO_SNDTIMEO, &sendTimeout, sizeof(sendTimeout));
            std::string auth;
            char ch;
            while (auth.size() < 64 && recv(connection, &ch, 1, 0) == 1 && ch != '\n') auth += ch;
            if (auth != secret || !running) { close(connection); continue; }
            bool accepted = false;
            {
                std::lock_guard<std::mutex> guard(socketMutex);
                if (client >= 0) { shutdown(client, SHUT_RDWR); close(client); }
                client = connection; needsHeader = true;
                // Static screens may not produce another frame for a long time.
                // Show the latest decodable frame immediately, then wait for a
                // fresh IDR before continuing the live stream.
                if (!codecHeader.empty() && !latestKeyframe.empty()) {
                    bool good = Packet(codecHeader.data(), codecHeader.size(), AVCODEC_BUFFER_FLAGS_CODEC_DATA, latestKeyframePTS)
                             && Packet(latestKeyframe.data(), latestKeyframe.size(), AVCODEC_BUFFER_FLAGS_SYNC_FRAME, latestKeyframePTS);
                    if (!good) { shutdown(client, SHUT_RDWR); close(client); client = -1; }
                }
                accepted = client >= 0;
            }
            if (accepted && encoder) {
                OH_AVFormat* request = OH_AVFormat_Create();
                if (request) {
                    OH_AVFormat_SetIntValue(request, OH_MD_KEY_REQUEST_I_FRAME, 1);
                    OH_VideoEncoder_SetParameter(encoder, request);
                    OH_AVFormat_Destroy(request);
                }
            }
        }
    });
    stage = 11;
    result = OH_AVScreenCapture_StartScreenCaptureWithSurface(capture, surface);
    if (result) { lastError = result; Stop(); }
    return result;
}

napi_value StartJS(napi_env env, napi_callback_info info) {
    size_t argc = 1; napi_value args[1]; napi_get_cb_info(env, info, &argc, args, nullptr, nullptr);
    char token[80]{}; size_t length = 0;
    if (argc != 1 || napi_get_value_string_utf8(env, args[0], token, sizeof(token), &length) != napi_ok || length != 32) {
        napi_throw_error(env, nullptr, "Invalid pairing token"); return nullptr;
    }
    int result = Start(std::string(token, length));
    OH_LOG_Print(LOG_APP, LOG_INFO, 0x1234, "HBridge", "Video start stage=%{public}d result=%{public}d", stage.load(), result);
    if (result) { lastError = result; Stop(); }
    napi_value value; napi_create_int32(env, result, &value); return value;
}
napi_value StopJS(napi_env env, napi_callback_info) { Stop(); napi_value value; napi_get_undefined(env, &value); return value; }
napi_value StatusJS(napi_env env, napi_callback_info) {
    std::string text = "{\"stage\":" + std::to_string(stage.load()) + ",\"state\":" + std::to_string(state.load()) + ",\"error\":" + std::to_string(lastError.load()) + ",\"frames\":" + std::to_string(frames.load()) + ",\"bytes\":" + std::to_string(totalBytes.load()) + "}";
    napi_value value; napi_create_string_utf8(env, text.c_str(), text.size(), &value); return value;
}
napi_value Init(napi_env env, napi_value exports) {
    napi_property_descriptor properties[] = {
        {"start", nullptr, StartJS, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"stop", nullptr, StopJS, nullptr, nullptr, nullptr, napi_default, nullptr},
        {"status", nullptr, StatusJS, nullptr, nullptr, nullptr, napi_default, nullptr}
    };
    napi_define_properties(env, exports, 3, properties); return exports;
}
napi_module module = {1,0,nullptr,Init,"bridge",nullptr,{0}};
__attribute__((constructor)) void Register() { napi_module_register(&module); }
}
