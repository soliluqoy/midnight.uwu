#include "publishing_availability.h"

#include <flutter/method_result_functions.h>
#include <flutter/standard_method_codec.h>
#include <shellapi.h>

#include <cstdint>
#include <cwchar>
#include <utility>
#include <vector>

#include "resource.h"

namespace {
constexpr UINT kTrayMessage = WM_APP + 80;
constexpr UINT kFinishQuitMessage = WM_APP + 81;
constexpr UINT_PTR kQuitTimer = 0x5641554c;
constexpr UINT kTrayIcon = 1;
constexpr UINT kOpenCommand = 1;
constexpr UINT kStopCommand = 2;
constexpr UINT kQuitCommand = 3;
constexpr wchar_t kRunKey[] =
    L"Software\\Microsoft\\Windows\\CurrentVersion\\Run";
constexpr wchar_t kRunValue[] = L"Vault";

NOTIFYICONDATAW TrayData(HWND window) {
  NOTIFYICONDATAW data{};
  data.cbSize = sizeof(data);
  data.hWnd = window;
  data.uID = kTrayIcon;
  return data;
}

void ShowNativeError(HWND window, const wchar_t* operation, DWORD error) {
  const std::wstring message = std::wstring(operation) +
      L" failed (Windows error " + std::to_wstring(error) + L").";
  MessageBoxW(window, message.c_str(), L"Midnight availability", MB_OK | MB_ICONERROR);
}
}  // namespace

PublishingAvailability::PublishingAvailability(
    HWND window, flutter::BinaryMessenger* messenger)
    : window_(window),
      taskbar_created_(RegisterWindowMessageW(L"TaskbarCreated")),
      callback_state_(std::make_shared<CallbackState>()),
      channel_(std::make_unique<flutter::MethodChannel<flutter::EncodableValue>>(
          messenger, "dev.vault/availability",
          &flutter::StandardMethodCodec::GetInstance())) {
  callback_state_->window = window;
  // Windows executable paths cannot exceed this UTF-16 buffer size.
  std::vector<wchar_t> executable(32768);
  const DWORD length = GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (length == 0) {
    executable_error_ = GetLastError();
  } else if (length >= executable.size()) {
    executable_error_ = ERROR_INSUFFICIENT_BUFFER;
  } else {
    autostart_command_ = L"\"" + std::wstring(executable.data(), length) + L"\"";
  }
  channel_->SetMethodCallHandler(
      [this](const auto& call, auto result) {
        HandleMethod(call, std::move(result));
      });
}

PublishingAvailability::~PublishingAvailability() {
  callback_state_->alive = false;
  KillTimer(window_, kQuitTimer);
  channel_->SetMethodCallHandler(nullptr);
  RemoveTray();
  if (wake_lock_held_) {
    SetThreadExecutionState(ES_CONTINUOUS);
  }
}

void PublishingAvailability::ReturnError(
    flutter::MethodResult<flutter::EncodableValue>* result,
    const std::string& operation, DWORD error) {
  result->Error("windows_availability_error",
                operation + " failed (Windows error " +
                    std::to_string(error) + ").",
                flutter::EncodableValue(static_cast<int64_t>(error)));
}

flutter::EncodableValue PublishingAvailability::Status(bool autostart) const {
  using flutter::EncodableValue;
  return EncodableValue(flutter::EncodableMap{
      {EncodableValue("platform"), EncodableValue("windows")},
      {EncodableValue("supported"), EncodableValue(true)},
      {EncodableValue("publishing"), EncodableValue(publishing_)},
      {EncodableValue("autostart"), EncodableValue(autostart)},
      {EncodableValue("canAutostart"), EncodableValue(true)},
      {EncodableValue("canMinimizeToTray"), EncodableValue(true)},
      {EncodableValue("backgroundMode"),
       EncodableValue("awakeWhilePublishing")},
      {EncodableValue("wakeLockHeld"), EncodableValue(wake_lock_held_)},
      {EncodableValue("detail"), EncodableValue(
          "Prevents automatic system sleep only while publishing. Does not "
          "guarantee network reachability or override explicit sleep, shutdown, "
          "or machine policy. Login startup opens Midnight without publishing.")},
  });
}

void PublishingAvailability::ReturnStatus(
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  bool autostart = false;
  DWORD error = ERROR_SUCCESS;
  if (!ReadAutostart(&autostart, &error)) {
    ReturnError(result.get(), "Read login startup", error);
    return;
  }
  result->Success(Status(autostart));
}

bool PublishingAvailability::ReadAutostart(bool* enabled, DWORD* error) const {
  *enabled = false;
  if (executable_error_ != ERROR_SUCCESS) {
    *error = executable_error_;
    return false;
  }
  DWORD bytes = 0;
  LSTATUS status = RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue,
                                RRF_RT_REG_SZ, nullptr, nullptr, &bytes);
  if (status == ERROR_FILE_NOT_FOUND || status == ERROR_PATH_NOT_FOUND) {
    return true;
  }
  if (status != ERROR_SUCCESS) {
    *error = static_cast<DWORD>(status);
    return false;
  }
  if (bytes > 131072 || bytes % sizeof(wchar_t) != 0) {
    *error = ERROR_INVALID_DATA;
    return false;
  }
  std::vector<wchar_t> command(bytes / sizeof(wchar_t) + 1, L'\0');
  status = RegGetValueW(HKEY_CURRENT_USER, kRunKey, kRunValue, RRF_RT_REG_SZ,
                        nullptr, command.data(), &bytes);
  if (status != ERROR_SUCCESS) {
    *error = static_cast<DWORD>(status);
    return false;
  }
  *enabled = autostart_command_ == command.data();
  return true;
}

bool PublishingAvailability::WriteAutostart(bool enabled, DWORD* error) const {
  if (enabled && executable_error_ != ERROR_SUCCESS) {
    *error = executable_error_;
    return false;
  }
  HKEY key = nullptr;
  LSTATUS status = RegCreateKeyExW(HKEY_CURRENT_USER, kRunKey, 0, nullptr, 0,
                                   KEY_SET_VALUE, nullptr, &key, nullptr);
  if (status != ERROR_SUCCESS) {
    *error = static_cast<DWORD>(status);
    return false;
  }
  if (enabled) {
    const DWORD bytes = static_cast<DWORD>(
        (autostart_command_.size() + 1) * sizeof(wchar_t));
    status = RegSetValueExW(
        key, kRunValue, 0, REG_SZ,
        reinterpret_cast<const BYTE*>(autostart_command_.c_str()), bytes);
  } else {
    status = RegDeleteValueW(key, kRunValue);
    if (status == ERROR_FILE_NOT_FOUND) {
      status = ERROR_SUCCESS;
    }
  }
  RegCloseKey(key);
  *error = static_cast<DWORD>(status);
  return status == ERROR_SUCCESS;
}

bool PublishingAvailability::EnsureTray(DWORD* error) {
  if (tray_present_) {
    return true;
  }
  if (taskbar_created_ == 0) {
    *error = ERROR_GEN_FAILURE;
    return false;
  }
  auto data = TrayData(window_);
  data.uFlags = NIF_MESSAGE | NIF_ICON | NIF_TIP;
  data.uCallbackMessage = kTrayMessage;
  // LoadIcon returns a shared resource; it must not be passed to DestroyIcon.
  data.hIcon = LoadIconW(GetModuleHandleW(nullptr), MAKEINTRESOURCEW(IDI_APP_ICON));
  if (data.hIcon == nullptr) {
    *error = GetLastError();
    return false;
  }
  wcscpy_s(data.szTip, publishing_ ? L"Midnight - publishing" : L"Midnight - stopped");
  if (!Shell_NotifyIconW(NIM_ADD, &data)) {
    *error = ERROR_GEN_FAILURE;
    return false;
  }
  tray_present_ = true;
  data.uVersion = NOTIFYICON_VERSION_4;
  if (!Shell_NotifyIconW(NIM_SETVERSION, &data)) {
    RemoveTray();
    *error = ERROR_GEN_FAILURE;
    return false;
  }
  return true;
}

bool PublishingAvailability::UpdateTray(DWORD* error) {
  if (!tray_present_) {
    return true;
  }
  auto data = TrayData(window_);
  data.uFlags = NIF_TIP;
  wcscpy_s(data.szTip, publishing_ ? L"Midnight - publishing" : L"Midnight - stopped");
  if (!Shell_NotifyIconW(NIM_MODIFY, &data)) {
    *error = ERROR_GEN_FAILURE;
    return false;
  }
  return true;
}

void PublishingAvailability::RemoveTray() {
  if (tray_present_) {
    auto data = TrayData(window_);
    Shell_NotifyIconW(NIM_DELETE, &data);
    tray_present_ = false;
  }
}

bool PublishingAvailability::StopNative(DWORD* error) {
  publishing_ = false;
  bool released = true;
  if (wake_lock_held_) {
    if (SetThreadExecutionState(ES_CONTINUOUS) == 0) {
      *error = ERROR_GEN_FAILURE;
      released = false;
    } else {
      wake_lock_held_ = false;
    }
  }
  DWORD tray_error = ERROR_SUCCESS;
  const bool updated = UpdateTray(&tray_error);
  if (!updated && released) {
    *error = tray_error;
  }
  return released && updated;
}

bool PublishingAvailability::HideToTray(DWORD* error) {
  if (!EnsureTray(error)) {
    return false;
  }
  auto data = TrayData(window_);
  data.uFlags = NIF_INFO;
  data.dwInfoFlags = NIIF_INFO | NIIF_NOSOUND;
  wcscpy_s(data.szInfoTitle, L"Midnight is in the notification area");
  wcscpy_s(data.szInfo,
           publishing_ ? L"Publishing continues. Use the Midnight tray menu to open "
                         L"Midnight, stop publishing, or quit."
                       : L"Publishing is stopped. Use the Midnight tray menu to "
                         L"open Midnight or quit.");
  if (!Shell_NotifyIconW(NIM_MODIFY, &data)) {
    *error = ERROR_GEN_FAILURE;
    return false;
  }
  ShowWindow(window_, SW_HIDE);
  return true;
}

void PublishingAvailability::ShowWindowFromTray() {
  ShowWindow(window_, SW_RESTORE);
  SetForegroundWindow(window_);
}

void PublishingAvailability::NotifyStopped(const std::string& reason, bool quit) {
  if (!quit) {
    channel_->InvokeMethod("stopped",
                          std::make_unique<flutter::EncodableValue>(reason));
    return;
  }
  const std::weak_ptr<CallbackState> weak_state = callback_state_;
  const auto finish = [weak_state]() {
    if (const auto state = weak_state.lock(); state && state->alive) {
      PostMessageW(state->window, kFinishQuitMessage, 0, 0);
    }
  };
  auto response =
      std::make_unique<flutter::MethodResultFunctions<flutter::EncodableValue>>(
          [finish](const flutter::EncodableValue*) { finish(); },
          [finish](const std::string&, const std::string&,
                   const flutter::EncodableValue*) { finish(); },
          finish);
  channel_->InvokeMethod("stopped",
                        std::make_unique<flutter::EncodableValue>(reason),
                        std::move(response));
}

void PublishingAvailability::BeginQuit() {
  if (quitting_) {
    return;
  }
  quitting_ = true;
  DWORD error = ERROR_SUCCESS;
  if (!StopNative(&error)) {
    ShowNativeError(window_, L"Stop availability", error);
  }
  // Give Dart time to stop delivery before destroying its engine. This one-shot
  // fallback also permits exit if Dart is unresponsive or a callback is lost.
  if (SetTimer(window_, kQuitTimer, 5000, nullptr) == 0) {
    NotifyStopped("trayQuit", false);
    PostMessageW(window_, kFinishQuitMessage, 0, 0);
    return;
  }
  NotifyStopped("trayQuit", true);
}

void PublishingAvailability::ShowTrayMenu() {
  HMENU menu = CreatePopupMenu();
  if (menu == nullptr) {
    ShowNativeError(window_, L"Create tray menu", GetLastError());
    return;
  }
  const bool populated =
      AppendMenuW(menu, MF_STRING, kOpenCommand, L"Open Midnight") &&
      AppendMenuW(menu, MF_STRING | (publishing_ ? MF_ENABLED : MF_GRAYED),
                  kStopCommand, L"Stop publishing") &&
      AppendMenuW(menu, MF_SEPARATOR, 0, nullptr) &&
      AppendMenuW(menu, MF_STRING, kQuitCommand, L"Quit Midnight");
  if (!populated) {
    const DWORD error = GetLastError();
    DestroyMenu(menu);
    ShowNativeError(window_, L"Populate tray menu", error);
    return;
  }
  POINT cursor{};
  GetCursorPos(&cursor);
  SetForegroundWindow(window_);
  const UINT command = static_cast<UINT>(TrackPopupMenuEx(
      menu, TPM_RETURNCMD | TPM_NONOTIFY | TPM_RIGHTBUTTON, cursor.x, cursor.y,
      window_, nullptr));
  DestroyMenu(menu);
  PostMessageW(window_, WM_NULL, 0, 0);
  if (command == kOpenCommand) {
    ShowWindowFromTray();
  } else if (command == kStopCommand) {
    DWORD error = ERROR_SUCCESS;
    const bool stopped = StopNative(&error);
    NotifyStopped("trayStop", false);
    if (!stopped) {
      ShowNativeError(window_, L"Stop availability", error);
    }
  } else if (command == kQuitCommand) {
    BeginQuit();
  }
}

void PublishingAvailability::HandleMethod(
    const flutter::MethodCall<flutter::EncodableValue>& call,
    std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result) {
  const auto& method = call.method_name();
  DWORD error = ERROR_SUCCESS;
  if (method == "status") {
    ReturnStatus(std::move(result));
  } else if (method == "start") {
    if (quitting_ || !IsWindowVisible(window_)) {
      result->Error("foreground_required",
                    "Open Midnight and explicitly publish from its foreground UI.");
      return;
    }
    bool autostart = false;
    if (!ReadAutostart(&autostart, &error)) {
      ReturnError(result.get(), "Read login startup", error);
      return;
    }
    if (!EnsureTray(&error)) {
      ReturnError(result.get(), "Create tray icon", error);
      return;
    }
    if (!wake_lock_held_ &&
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED) == 0) {
      ReturnError(result.get(), "Prevent automatic system sleep", ERROR_GEN_FAILURE);
      return;
    }
    wake_lock_held_ = true;
    publishing_ = true;
    if (!UpdateTray(&error)) {
      DWORD ignored = ERROR_SUCCESS;
      StopNative(&ignored);
      ReturnError(result.get(), "Update tray icon", error);
      return;
    }
    result->Success(Status(autostart));
  } else if (method == "stop") {
    if (!StopNative(&error)) {
      ReturnError(result.get(), "Stop availability", error);
      return;
    }
    ReturnStatus(std::move(result));
  } else if (method == "setAutostart") {
    const auto* arguments = call.arguments();
    const auto* map = arguments == nullptr
                          ? nullptr
                          : std::get_if<flutter::EncodableMap>(arguments);
    if (map == nullptr) {
      result->Error("invalid_arguments", "Expected {enabled: bool}.");
      return;
    }
    const auto entry = map->find(flutter::EncodableValue("enabled"));
    const bool* enabled = entry == map->end()
                              ? nullptr
                              : std::get_if<bool>(&entry->second);
    if (enabled == nullptr) {
      result->Error("invalid_arguments", "Expected {enabled: bool}.");
      return;
    }
    if (!WriteAutostart(*enabled, &error)) {
      ReturnError(result.get(), "Change login startup", error);
      return;
    }
    ReturnStatus(std::move(result));
  } else if (method == "minimizeToTray") {
    if (!HideToTray(&error)) {
      ReturnError(result.get(), "Minimize to tray", error);
      return;
    }
    ReturnStatus(std::move(result));
  } else {
    result->NotImplemented();
  }
}

std::optional<LRESULT> PublishingAvailability::HandleMessage(
    UINT message, WPARAM wparam, LPARAM lparam) {
  if (taskbar_created_ != 0 && message == taskbar_created_) {
    if (tray_present_) {
      tray_present_ = false;
      DWORD error = ERROR_SUCCESS;
      if (!EnsureTray(&error)) {
        const DWORD tray_error = error;
        StopNative(&error);
        ShowWindowFromTray();
        NotifyStopped("trayUnavailable", false);
        ShowNativeError(window_, L"Restore tray icon", tray_error);
      }
    }
    return 0;
  }
  switch (message) {
    case kTrayMessage:
      if (LOWORD(lparam) == NIN_SELECT || LOWORD(lparam) == NIN_KEYSELECT) {
        ShowWindowFromTray();
      } else if (LOWORD(lparam) == WM_CONTEXTMENU) {
        ShowTrayMenu();
      }
      return 0;
    case WM_CLOSE:
      if (allow_close_) {
        return std::nullopt;
      }
      if (quitting_) {
        return 0;
      }
      if (publishing_) {
        if (MessageBoxW(
                window_,
                L"Midnight will continue publishing in the notification area. "
                L"Use its tray menu to open Midnight, stop publishing, or quit.",
                L"Keep Midnight publishing in the tray?",
                MB_OKCANCEL | MB_ICONINFORMATION) != IDOK) {
          return 0;
        }
        DWORD error = ERROR_SUCCESS;
        if (!HideToTray(&error)) {
          ShowNativeError(window_, L"Minimize to tray", error);
        }
        return 0;
      }
      break;
    case WM_TIMER:
      if (wparam == kQuitTimer) {
        KillTimer(window_, kQuitTimer);
        PostMessageW(window_, kFinishQuitMessage, 0, 0);
        return 0;
      }
      break;
    case kFinishQuitMessage:
      if (quitting_) {
        KillTimer(window_, kQuitTimer);
        allow_close_ = true;
        PostMessageW(window_, WM_CLOSE, 0, 0);
      }
      return 0;
    case WM_POWERBROADCAST:
      if (wparam == PBT_APMSUSPEND && publishing_) {
        DWORD error = ERROR_SUCCESS;
        StopNative(&error);
        NotifyStopped("systemSuspend", false);
      }
      break;
    case WM_ENDSESSION:
      if (wparam != FALSE) {
        DWORD error = ERROR_SUCCESS;
        StopNative(&error);
        NotifyStopped("sessionEnding", false);
      }
      break;
  }
  return std::nullopt;
}
