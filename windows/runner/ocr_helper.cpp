#include "ocr_helper.h"

#include <flutter/standard_method_codec.h>
#include <roapi.h>
#include <robuffer.h>
#include <windows.foundation.collections.h>
#include <windows.foundation.h>
#include <windows.globalization.h>
#include <windows.graphics.imaging.h>
#include <windows.media.ocr.h>
#include <windows.storage.streams.h>
#include <winstring.h>
#include <wrl/client.h>
#include <wrl/wrappers/corewrappers.h>

#include <algorithm>
#include <cstring>
#include <thread>
#include <vector>

using Microsoft::WRL::ComPtr;
using Microsoft::WRL::Wrappers::HString;
using Microsoft::WRL::Wrappers::HStringReference;

namespace {

std::string HStringToUtf8(HSTRING hstr) {
  if (hstr == nullptr) return "";
  UINT32 len = 0;
  const wchar_t* raw = WindowsGetStringRawBuffer(hstr, &len);
  if (raw == nullptr || len == 0) return "";
  int bytes = WideCharToMultiByte(CP_UTF8, 0, raw, static_cast<int>(len), nullptr, 0, nullptr, nullptr);
  if (bytes <= 0) return "";
  std::string out(static_cast<size_t>(bytes), '\0');
  WideCharToMultiByte(CP_UTF8, 0, raw, static_cast<int>(len), out.data(), bytes, nullptr, nullptr);
  return out;
}

template <typename Op, typename Res>
HRESULT AwaitAsyncOp(Op* op, Res* out_result) {
  if (op == nullptr || out_result == nullptr) return E_POINTER;
  ComPtr<ABI::Windows::Foundation::IAsyncInfo> info;
  HRESULT hr = op->QueryInterface(IID_PPV_ARGS(&info));
  if (FAILED(hr)) return hr;
  ABI::Windows::Foundation::AsyncStatus status =
      ABI::Windows::Foundation::AsyncStatus::Started;
  for (int i = 0; i < 6000; ++i) {
    hr = info->get_Status(&status);
    if (FAILED(hr)) return hr;
    if (status != ABI::Windows::Foundation::AsyncStatus::Started) break;
    Sleep(5);
  }
  if (status != ABI::Windows::Foundation::AsyncStatus::Completed) {
    HRESULT err = E_FAIL;
    info->get_ErrorCode(&err);
    return FAILED(err) ? err : E_FAIL;
  }
  return op->GetResults(out_result);
}

HRESULT TryCreateOcrEngineForTag(
    ABI::Windows::Media::Ocr::IOcrEngineStatics* ocr_statics,
    ABI::Windows::Globalization::ILanguageFactory* lang_factory,
    const wchar_t* tag,
    ABI::Windows::Media::Ocr::IOcrEngine** out_engine) {
  HStringReference htag(tag);
  ComPtr<ABI::Windows::Globalization::ILanguage> lang;
  HRESULT hr = lang_factory->CreateLanguage(htag.Get(), &lang);
  if (FAILED(hr) || !lang) return FAILED(hr) ? hr : E_FAIL;

  boolean supported = FALSE;
  hr = ocr_statics->IsLanguageSupported(lang.Get(), &supported);
  if (FAILED(hr) || !supported) return E_FAIL;

  return ocr_statics->TryCreateFromLanguage(lang.Get(), out_engine);
}

bool RunWindowsOcrSync(
    const std::vector<uint8_t>& image_bytes,
    flutter::EncodableMap* out_map,
    std::string* out_err_code,
    std::string* out_err_msg) {
  HRESULT hr_init = RoInitialize(RO_INIT_MULTITHREADED);
  bool did_init = SUCCEEDED(hr_init);
  if (hr_init == RPC_E_CHANGED_MODE) {
    did_init = false;
  } else if (FAILED(hr_init)) {
    *out_err_code = "WINRT_INIT_FAILED";
    *out_err_msg = "无法初始化 Windows OCR 运行时";
    return false;
  }

  auto cleanup_ro = [did_init]() {
    if (did_init) {
      RoUninitialize();
    }
  };

  // 1. 创建内存随机访问流并写入图像字节
  ComPtr<IInspectable> stream_insp;
  HRESULT hr = RoActivateInstance(
      HStringReference(RuntimeClass_Windows_Storage_Streams_InMemoryRandomAccessStream).Get(),
      &stream_insp);
  ComPtr<ABI::Windows::Storage::Streams::IRandomAccessStream> stream;
  if (SUCCEEDED(hr)) hr = stream_insp.As(&stream);
  if (FAILED(hr) || !stream) {
    cleanup_ro();
    *out_err_code = "STREAM_FAILED";
    *out_err_msg = "创建图像内存流失败";
    return false;
  }

  ComPtr<ABI::Windows::Storage::Streams::IBufferFactory> buf_factory;
  hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Storage_Streams_Buffer).Get(),
      IID_PPV_ARGS(&buf_factory));
  ComPtr<ABI::Windows::Storage::Streams::IBuffer> buffer;
  if (SUCCEEDED(hr)) {
    hr = buf_factory->Create(static_cast<UINT32>(image_bytes.size()), &buffer);
  }
  if (SUCCEEDED(hr)) {
    hr = buffer->put_Length(static_cast<UINT32>(image_bytes.size()));
  }
  ComPtr<Windows::Storage::Streams::IBufferByteAccess> byte_access;
  if (SUCCEEDED(hr)) hr = buffer.As(&byte_access);
  byte* raw_buf = nullptr;
  if (SUCCEEDED(hr)) hr = byte_access->Buffer(&raw_buf);
  if (FAILED(hr) || raw_buf == nullptr) {
    cleanup_ro();
    *out_err_code = "BUFFER_FAILED";
    *out_err_msg = "分配图像缓冲区失败";
    return false;
  }
  std::memcpy(raw_buf, image_bytes.data(), image_bytes.size());

  ComPtr<ABI::Windows::Storage::Streams::IOutputStream> out_stream;
  hr = stream->GetOutputStreamAt(0, &out_stream);
  ComPtr<ABI::Windows::Foundation::IAsyncOperationWithProgress<UINT32, UINT32>> write_op;
  if (SUCCEEDED(hr)) hr = out_stream->WriteAsync(buffer.Get(), &write_op);
  if (SUCCEEDED(hr)) {
    ComPtr<ABI::Windows::Foundation::IAsyncInfo> write_info;
    hr = write_op.As(&write_info);
    if (SUCCEEDED(hr)) {
      ABI::Windows::Foundation::AsyncStatus st =
          ABI::Windows::Foundation::AsyncStatus::Started;
      for (int i = 0; i < 2000; ++i) {
        write_info->get_Status(&st);
        if (st != ABI::Windows::Foundation::AsyncStatus::Started) break;
        Sleep(2);
      }
      if (st != ABI::Windows::Foundation::AsyncStatus::Completed) {
        hr = E_FAIL;
      }
    }
  }
  if (SUCCEEDED(hr)) hr = stream->Seek(0);
  if (FAILED(hr)) {
    cleanup_ro();
    *out_err_code = "WRITE_STREAM_FAILED";
    *out_err_msg = "写入图像数据失败";
    return false;
  }

  // 2. 解码为 SoftwareBitmap (Bgra8)
  ComPtr<ABI::Windows::Graphics::Imaging::IBitmapDecoderStatics> decoder_statics;
  hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Graphics_Imaging_BitmapDecoder).Get(),
      IID_PPV_ARGS(&decoder_statics));
  ComPtr<ABI::Windows::Foundation::IAsyncOperation<ABI::Windows::Graphics::Imaging::BitmapDecoder*>>
      decode_op;
  if (SUCCEEDED(hr)) hr = decoder_statics->CreateAsync(stream.Get(), &decode_op);
  ComPtr<ABI::Windows::Graphics::Imaging::IBitmapDecoder> decoder;
  if (SUCCEEDED(hr)) hr = AwaitAsyncOp(decode_op.Get(), decoder.GetAddressOf());
  if (FAILED(hr) || !decoder) {
    cleanup_ro();
    *out_err_code = "DECODE_FAILED";
    *out_err_msg = "无法解码图片进行文字识别";
    return false;
  }

  ComPtr<ABI::Windows::Graphics::Imaging::IBitmapFrame> frame;
  hr = decoder.As(&frame);
  UINT32 px_w = 0;
  UINT32 px_h = 0;
  if (SUCCEEDED(hr)) hr = frame->get_PixelWidth(&px_w);
  if (SUCCEEDED(hr)) hr = frame->get_PixelHeight(&px_h);

  ComPtr<ABI::Windows::Graphics::Imaging::IBitmapFrameWithSoftwareBitmap> frame_sb;
  if (SUCCEEDED(hr)) hr = decoder.As(&frame_sb);
  ComPtr<ABI::Windows::Foundation::IAsyncOperation<ABI::Windows::Graphics::Imaging::SoftwareBitmap*>>
      sb_op;
  if (SUCCEEDED(hr)) hr = frame_sb->GetSoftwareBitmapAsync(&sb_op);
  ComPtr<ABI::Windows::Graphics::Imaging::ISoftwareBitmap> software_bitmap;
  if (SUCCEEDED(hr)) hr = AwaitAsyncOp(sb_op.Get(), software_bitmap.GetAddressOf());
  if (FAILED(hr) || !software_bitmap || px_w == 0 || px_h == 0) {
    cleanup_ro();
    *out_err_code = "BITMAP_FAILED";
    *out_err_msg = "获取位图失败";
    return false;
  }

  ComPtr<ABI::Windows::Graphics::Imaging::ISoftwareBitmapStatics> sb_statics;
  hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Graphics_Imaging_SoftwareBitmap).Get(),
      IID_PPV_ARGS(&sb_statics));
  ComPtr<ABI::Windows::Graphics::Imaging::ISoftwareBitmap> bgra_bitmap;
  if (SUCCEEDED(hr)) {
    hr = sb_statics->Convert(
        software_bitmap.Get(),
        ABI::Windows::Graphics::Imaging::BitmapPixelFormat_Bgra8,
        &bgra_bitmap);
  }
  if (FAILED(hr) || !bgra_bitmap) {
    bgra_bitmap = software_bitmap;
  }

  // 3. 创建 OcrEngine（优先简体中文，回退系统语言）
  ComPtr<ABI::Windows::Media::Ocr::IOcrEngineStatics> ocr_statics;
  hr = RoGetActivationFactory(
      HStringReference(RuntimeClass_Windows_Media_Ocr_OcrEngine).Get(),
      IID_PPV_ARGS(&ocr_statics));
  ComPtr<ABI::Windows::Globalization::ILanguageFactory> lang_factory;
  if (SUCCEEDED(hr)) {
    RoGetActivationFactory(
        HStringReference(RuntimeClass_Windows_Globalization_Language).Get(),
        IID_PPV_ARGS(&lang_factory));
  }

  ComPtr<ABI::Windows::Media::Ocr::IOcrEngine> engine;
  if (ocr_statics && lang_factory) {
    if (FAILED(TryCreateOcrEngineForTag(ocr_statics.Get(), lang_factory.Get(), L"zh-Hans", &engine)) ||
        !engine) {
      TryCreateOcrEngineForTag(ocr_statics.Get(), lang_factory.Get(), L"zh-CN", &engine);
    }
  }
  if (!engine && ocr_statics) {
    ocr_statics->TryCreateFromUserProfileLanguages(&engine);
  }
  if (!engine) {
    cleanup_ro();
    *out_err_code = "NO_OCR_LANGUAGE";
    *out_err_msg = "未找到可用的 Windows OCR 语言包，请在系统设置安装中文或英文语言包";
    return false;
  }

  // 4. 识别文字与行级坐标
  ComPtr<ABI::Windows::Foundation::IAsyncOperation<ABI::Windows::Media::Ocr::OcrResult*>> rec_op;
  hr = engine->RecognizeAsync(bgra_bitmap.Get(), &rec_op);
  ComPtr<ABI::Windows::Media::Ocr::IOcrResult> ocr_result;
  if (SUCCEEDED(hr)) hr = AwaitAsyncOp(rec_op.Get(), ocr_result.GetAddressOf());
  if (FAILED(hr) || !ocr_result) {
    cleanup_ro();
    *out_err_code = "OCR_FAILED";
    *out_err_msg = "Windows OCR 识别失败";
    return false;
  }

  HString full_text_hs;
  ocr_result->get_Text(full_text_hs.GetAddressOf());
  std::string full_text = HStringToUtf8(full_text_hs.Get());

  flutter::EncodableList enc_lines;
  ComPtr<ABI::Windows::Foundation::Collections::IVectorView<ABI::Windows::Media::Ocr::OcrLine*>>
      lines_view;
  if (SUCCEEDED(ocr_result->get_Lines(&lines_view)) && lines_view) {
    UINT32 line_count = 0;
    lines_view->get_Size(&line_count);
    const double dw = static_cast<double>(px_w);
    const double dh = static_cast<double>(px_h);
    for (UINT32 i = 0; i < line_count; ++i) {
      ComPtr<ABI::Windows::Media::Ocr::IOcrLine> line;
      if (FAILED(lines_view->GetAt(i, &line)) || !line) continue;
      HString line_hs;
      line->get_Text(line_hs.GetAddressOf());
      std::string line_str = HStringToUtf8(line_hs.Get());
      if (line_str.empty()) continue;

      double min_x = 1.0, min_y = 1.0, max_x = 0.0, max_y = 0.0;
      bool has_box = false;
      ComPtr<ABI::Windows::Foundation::Collections::IVectorView<ABI::Windows::Media::Ocr::OcrWord*>>
          words_view;
      if (SUCCEEDED(line->get_Words(&words_view)) && words_view) {
        UINT32 wc = 0;
        words_view->get_Size(&wc);
        for (UINT32 w = 0; w < wc; ++w) {
          ComPtr<ABI::Windows::Media::Ocr::IOcrWord> word;
          if (FAILED(words_view->GetAt(w, &word)) || !word) continue;
          ABI::Windows::Foundation::Rect rect{};
          if (FAILED(word->get_BoundingRect(&rect))) continue;
          double l = std::clamp(static_cast<double>(rect.X) / dw, 0.0, 1.0);
          double t = std::clamp(static_cast<double>(rect.Y) / dh, 0.0, 1.0);
          double r = std::clamp(static_cast<double>(rect.X + rect.Width) / dw, 0.0, 1.0);
          double b = std::clamp(static_cast<double>(rect.Y + rect.Height) / dh, 0.0, 1.0);
          if (!has_box) {
            min_x = l; min_y = t; max_x = r; max_y = b;
            has_box = true;
          } else {
            min_x = std::min(min_x, l);
            min_y = std::min(min_y, t);
            max_x = std::max(max_x, r);
            max_y = std::max(max_y, b);
          }
        }
      }
      if (!has_box) {
        min_x = 0.05; min_y = 0.05; max_x = 0.95; max_y = 0.10;
      }
      flutter::EncodableMap line_map;
      line_map[flutter::EncodableValue("text")] = flutter::EncodableValue(line_str);
      line_map[flutter::EncodableValue("left")] = flutter::EncodableValue(min_x);
      line_map[flutter::EncodableValue("top")] = flutter::EncodableValue(min_y);
      line_map[flutter::EncodableValue("right")] = flutter::EncodableValue(max_x);
      line_map[flutter::EncodableValue("bottom")] = flutter::EncodableValue(max_y);
      enc_lines.push_back(flutter::EncodableValue(line_map));
    }
  }

  (*out_map)[flutter::EncodableValue("text")] = flutter::EncodableValue(full_text);
  (*out_map)[flutter::EncodableValue("lines")] = flutter::EncodableValue(enc_lines);
  cleanup_ro();
  return true;
}

}  // namespace

void RegisterWindowsOcrChannel(
    flutter::BinaryMessenger* messenger,
    HWND hwnd,
    std::shared_ptr<std::atomic<bool>> window_alive) {
  auto channel = std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
      messenger, "com.saomiao.saomiao_flutter/ocr",
      &flutter::StandardMethodCodec::GetInstance());

  channel->SetMethodCallHandler(
      [hwnd, window_alive](
          const flutter::MethodCall<flutter::EncodableValue>& call,
          std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
        if (call.method_name() != "recognizeText") {
          result->NotImplemented();
          return;
        }
        const auto* args = std::get_if<flutter::EncodableMap>(call.arguments());
        if (!args) {
          result->Error("INVALID_ARGS", "参数格式无效");
          return;
        }
        auto it = args->find(flutter::EncodableValue("bytes"));
        if (it == args->end()) {
          result->Error("INVALID_IMAGE", "图片数据为空");
          return;
        }
        const auto* bytes_ptr = std::get_if<std::vector<uint8_t>>(&it->second);
        if (!bytes_ptr || bytes_ptr->empty()) {
          result->Error("INVALID_IMAGE", "图片数据为空");
          return;
        }

        std::vector<uint8_t> copied_bytes = *bytes_ptr;
        auto* raw_result = result.release();
        std::thread([hwnd, window_alive, copied_bytes = std::move(copied_bytes), raw_result]() mutable {
          auto payload = std::make_unique<OcrAsyncPayload>();
          payload->result.reset(raw_result);
          payload->ok = RunWindowsOcrSync(
              copied_bytes,
              &payload->response,
              &payload->error_code,
              &payload->error_message);
          if (window_alive->load() && IsWindow(hwnd)) {
            OcrAsyncPayload* raw_payload = payload.release();
            if (!PostMessage(hwnd, kWmOcrComplete, 0, reinterpret_cast<LPARAM>(raw_payload))) {
              delete raw_payload;
            }
          }
        }).detach();
      });

  // 持有 channel 生命周期直到进程退出
  static std::vector<std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>>> s_channels;
  s_channels.push_back(std::move(channel));
}
