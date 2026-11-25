#ifndef RUNNER_OCR_HELPER_H_
#define RUNNER_OCR_HELPER_H_

#include <windows.h>

#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>

#include <atomic>
#include <cstdint>
#include <memory>
#include <string>
#include <vector>

constexpr UINT kWmOcrComplete = WM_APP + 101;

struct OcrAsyncPayload {
  std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result;
  bool ok = false;
  std::string error_code;
  std::string error_message;
  flutter::EncodableMap response;
};

void RegisterWindowsOcrChannel(
    flutter::BinaryMessenger* messenger,
    HWND hwnd,
    std::shared_ptr<std::atomic<bool>> window_alive);

#endif  // RUNNER_OCR_HELPER_H_
