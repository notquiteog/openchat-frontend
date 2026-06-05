#include "utils.h"

#include <flutter_windows.h>
#include <io.h>
#include <stdio.h>
#include <windows.h>

#include <iostream>
#include <string>

namespace {
constexpr size_t kMaxExecutablePathChars = 32767;

bool SetRegistryString(HKEY key, const wchar_t* value_name,
                       const std::wstring& value) {
  return ::RegSetValueExW(
             key, value_name, 0, REG_SZ,
             reinterpret_cast<const BYTE*>(value.c_str()),
             static_cast<DWORD>((value.size() + 1) * sizeof(wchar_t))) ==
         ERROR_SUCCESS;
}
}  // namespace

void CreateAndAttachConsole() {
  if (::AllocConsole()) {
    FILE *unused;
    if (freopen_s(&unused, "CONOUT$", "w", stdout)) {
      _dup2(_fileno(stdout), 1);
    }
    if (freopen_s(&unused, "CONOUT$", "w", stderr)) {
      _dup2(_fileno(stdout), 2);
    }
    std::ios::sync_with_stdio();
    FlutterDesktopResyncOutputStreams();
  }
}

void RegisterUrlProtocol(const wchar_t* scheme, const wchar_t* display_name) {
  if (scheme == nullptr || scheme[0] == L'\0') {
    return;
  }

  std::wstring executable(kMaxExecutablePathChars, L'\0');
  DWORD length = ::GetModuleFileNameW(
      nullptr, executable.data(), static_cast<DWORD>(executable.size()));
  if (length == 0 || length >= executable.size()) {
    return;
  }
  executable.resize(length);

  const std::wstring base_key = L"Software\\Classes\\" + std::wstring(scheme);
  HKEY protocol_key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER, base_key.c_str(), 0, nullptr, 0,
                        KEY_WRITE, nullptr, &protocol_key, nullptr) !=
      ERROR_SUCCESS) {
    return;
  }

  const std::wstring label =
      display_name != nullptr && display_name[0] != L'\0'
          ? display_name
          : scheme;
  SetRegistryString(protocol_key, nullptr, L"URL:" + label);
  SetRegistryString(protocol_key, L"URL Protocol", L"");
  ::RegCloseKey(protocol_key);

  HKEY command_key = nullptr;
  if (::RegCreateKeyExW(HKEY_CURRENT_USER,
                        (base_key + L"\\shell\\open\\command").c_str(), 0,
                        nullptr, 0, KEY_WRITE, nullptr, &command_key,
                        nullptr) != ERROR_SUCCESS) {
    return;
  }

  SetRegistryString(command_key, nullptr, L"\"" + executable + L"\" \"%1\"");
  ::RegCloseKey(command_key);
}

std::vector<std::string> GetCommandLineArguments() {
  // Convert the UTF-16 command line arguments to UTF-8 for the Engine to use.
  int argc;
  wchar_t** argv = ::CommandLineToArgvW(::GetCommandLineW(), &argc);
  if (argv == nullptr) {
    return std::vector<std::string>();
  }

  std::vector<std::string> command_line_arguments;

  // Skip the first argument as it's the binary name.
  for (int i = 1; i < argc; i++) {
    command_line_arguments.push_back(Utf8FromUtf16(argv[i]));
  }

  ::LocalFree(argv);

  return command_line_arguments;
}

std::string Utf8FromUtf16(const wchar_t* utf16_string) {
  if (utf16_string == nullptr) {
    return std::string();
  }
  // First, find the length of the string with a safe upper bound (CWE-126).
  // UNICODE_STRING_MAX_CHARS (32767) is the maximum length of a UNICODE_STRING.
  int input_length = static_cast<int>(wcsnlen(utf16_string, UNICODE_STRING_MAX_CHARS));
  // Now use that bounded length to determine the required buffer size.
  // When an explicit length is passed, WideCharToMultiByte does not include
  // the null terminator in its returned size.
  int target_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, nullptr, 0, nullptr, nullptr);
  std::string utf8_string;
  if (target_length == 0 || static_cast<size_t>(target_length) > utf8_string.max_size()) {
    return utf8_string;
  }
  utf8_string.resize(target_length);
  int converted_length = ::WideCharToMultiByte(
      CP_UTF8, WC_ERR_INVALID_CHARS, utf16_string,
      input_length, utf8_string.data(), target_length, nullptr, nullptr);
  if (converted_length == 0) {
    return std::string();
  }
  return utf8_string;
}
