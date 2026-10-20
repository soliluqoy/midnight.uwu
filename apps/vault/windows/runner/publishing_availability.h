#ifndef RUNNER_PUBLISHING_AVAILABILITY_H_
#define RUNNER_PUBLISHING_AVAILABILITY_H_

#include <flutter/binary_messenger.h>
#include <flutter/encodable_value.h>
#include <flutter/method_channel.h>
#include <windows.h>

#include <memory>
#include <optional>
#include <string>

// Owns the tray icon, opt-in sleep request, and availability platform channel.
// This object and its channel run on the Flutter platform/window thread.
class PublishingAvailability {
 public:
  PublishingAvailability(HWND window, flutter::BinaryMessenger* messenger);
  ~PublishingAvailability();

  PublishingAvailability(const PublishingAvailability&) = delete;
  PublishingAvailability& operator=(const PublishingAvailability&) = delete;

  std::optional<LRESULT> HandleMessage(UINT message, WPARAM wparam,
                                       LPARAM lparam);

 private:
  struct CallbackState {
    HWND window = nullptr;
    bool alive = true;
  };

  void HandleMethod(
      const flutter::MethodCall<flutter::EncodableValue>& call,
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  bool ReadAutostart(bool* enabled, DWORD* error) const;
  bool WriteAutostart(bool enabled, DWORD* error) const;
  bool EnsureTray(DWORD* error);
  bool UpdateTray(DWORD* error);
  void RemoveTray();
  bool StopNative(DWORD* error);
  void NotifyStopped(const std::string& reason, bool quit);
  void BeginQuit();
  void ShowWindowFromTray();
  void ShowTrayMenu();
  bool HideToTray(DWORD* error);
  flutter::EncodableValue Status(bool autostart) const;
  void ReturnStatus(
      std::unique_ptr<flutter::MethodResult<flutter::EncodableValue>> result);
  static void ReturnError(flutter::MethodResult<flutter::EncodableValue>* result,
                          const std::string& operation, DWORD error);

  HWND window_;
  UINT taskbar_created_;
  bool publishing_ = false;
  bool wake_lock_held_ = false;
  bool tray_present_ = false;
  bool quitting_ = false;
  bool allow_close_ = false;
  std::wstring autostart_command_;
  DWORD executable_error_ = ERROR_SUCCESS;
  std::shared_ptr<CallbackState> callback_state_;
  std::unique_ptr<flutter::MethodChannel<flutter::EncodableValue>> channel_;
};

#endif  // RUNNER_PUBLISHING_AVAILABILITY_H_
