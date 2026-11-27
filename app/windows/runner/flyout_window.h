#ifndef RUNNER_FLYOUT_WINDOW_H_
#define RUNNER_FLYOUT_WINDOW_H_

// Must precede <windows.h>: disables the min/max macros that break std::min.
#ifndef NOMINMAX
#define NOMINMAX
#endif

#include <windows.h>

#include <functional>
#include <string>
#include <unordered_map>
#include <vector>

// Native tray flyout (volet rapide): a real Win32 popup created HIDDEN at app
// startup — showing it is a plain ShowWindow (instant, no Flutter engine).
// Data (pinned lists + items) is pushed from Dart through the method channel;
// user actions (check, add, delete, select list, pin) are sent back to Dart,
// which applies them to the local DB (drift watch re-pushes fresh data).
//
// Visual: follows the Windows app theme (light/dark, live via
// WM_SETTINGCHANGE), owner-drawn flat icon buttons with hover states, list
// colors on the chips — the Windows 11 look, drawn by hand.
class FlyoutWindow {
 public:
  // Called for every user action. |action|: check/uncheck/delete/add/select/
  // pin/close. |a|/|b|: item/list id, text, bool ("true"/"false").
  using EventCallback =
      std::function<void(const std::string& action, const std::string& a,
                          const std::string& b)>;

  FlyoutWindow();
  ~FlyoutWindow();

  bool Create(EventCallback on_event);
  void Show(bool pinned);
  void Hide();
  bool visible() const { return visible_; }
  void UpdateData(const std::string& payload);

 private:
  struct ListInfo {
    std::string id;
    std::string title;
    int color;  // 0x00BBGGRR, 0 = default
  };
  struct ItemInfo {
    std::string id;
    bool done;
    std::string label;
    std::string due;  // localized badge, may be empty
  };

  static LRESULT CALLBACK WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;
  LRESULT MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                          LPARAM lparam);
  static LRESULT CALLBACK SubProc(HWND hwnd, UINT message, WPARAM wparam,
                                  LPARAM lparam) noexcept;

  void BuildControls();
  void Layout(int width, int height);
  void RebuildChips(int width);
  void RebuildItems();
  void RefreshTheme();
  void ApplyThemeToChildren();
  void DrawIconButton(const DRAWITEMSTRUCT* dis, const wchar_t* glyph,
                      COLORREF glyph_color);
  void DrawChip(const DRAWITEMSTRUCT* dis, const ListInfo& list, bool active);
  void DrawListItem(const DRAWITEMSTRUCT* dis);
  RECT CheckboxRectFor(const RECT& item_rect) const;
  void DoQuickAdd();
  void SendEvent(const std::string& action, const std::string& a = "",
                 const std::string& b = "");
  static std::wstring ToWide(const std::string& utf8);
  static std::string ToUtf8(const std::wstring& wide);
  static int ParseColor(const std::string& hex);

  HWND window_ = nullptr;
  HWND pin_btn_ = nullptr;
  HWND open_btn_ = nullptr;
  HWND close_btn_ = nullptr;
  HWND title_ = nullptr;
  HWND items_list_ = nullptr;
  HWND quick_add_ = nullptr;
  HWND add_btn_ = nullptr;
  HWND status_ = nullptr;
  HFONT font_ = nullptr;
  HFONT font_small_ = nullptr;
  HFONT font_icons_ = nullptr;
  HFONT font_bold_ = nullptr;
  HBRUSH bg_brush_ = nullptr;
  HBRUSH field_brush_ = nullptr;
  WNDPROC default_edit_proc_ = nullptr;
  WNDPROC default_list_proc_ = nullptr;
  WNDPROC default_btn_proc_ = nullptr;
  int chips_rows_ = 1;
  // C2.5 : les chips ne sont recréées que si la largeur (ou les listes)
  // ont réellement changé — pas à chaque pixel de WM_SIZE.
  int last_chip_width_ = -1;
  size_t last_chip_sig_ = 0;

  std::vector<ListInfo> lists_;
  std::vector<ItemInfo> items_;
  std::vector<HWND> chips_;
  std::unordered_map<HWND, bool> hover_;
  std::string active_;
  // Localized labels pushed from Dart (per-user synced language).
  std::wstring delete_label_ = L"Supprimer";
  std::wstring empty_label_ = L"Rien à faire";
  std::wstring no_lists_label_ = L"Épinglez des listes dans l'application.";
  // Theme (light/dark), refreshed from the Windows registry.
  bool dark_ = false;
  COLORREF c_bg_ = 0;
  COLORREF c_text_ = 0;
  COLORREF c_subtle_ = 0;
  COLORREF c_hover_ = 0;
  COLORREF c_field_ = 0;
  bool show_open_ = true;
  bool pinned_ = false;
  bool visible_ = false;
  bool suppress_check_events_ = false;
  DWORD shown_tick_ = 0;
  EventCallback on_event_;

  static constexpr int kDefaultWidth = 360;
  static constexpr int kDefaultHeight = 520;
};

#endif  // RUNNER_FLYOUT_WINDOW_H_
