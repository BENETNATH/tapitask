#include "flyout_window.h"

#include <commctrl.h>
#include <windows.h>
#include <windowsx.h>

#include <cstdint>
#include <utility>

#include <algorithm>

namespace {

const wchar_t kClassName[] = L"TapitaskFlyout";

std::wstring ToWideImpl(const std::string& utf8) {
  if (utf8.empty()) return std::wstring();
  int len = MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, nullptr, 0);
  std::wstring out(len - 1, L'\0');
  MultiByteToWideChar(CP_UTF8, 0, utf8.c_str(), -1, out.data(), len);
  return out;
}

std::string ToUtf8Impl(const std::wstring& wide) {
  if (wide.empty()) return std::string();
  int len = WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, nullptr, 0,
                                nullptr, nullptr);
  std::string out(len - 1, '\0');
  WideCharToMultiByte(CP_UTF8, 0, wide.c_str(), -1, out.data(), len, nullptr,
                      nullptr);
  return out;
}

// Diagnostic log: %TEMP%\tapitask_flyout.log — tells us exactly what the
// flyout did (created, shown, hidden, activation events).
void Flog(const char* msg) {
  char path[MAX_PATH];
  if (GetEnvironmentVariableA("TEMP", path, MAX_PATH) == 0) return;
  lstrcatA(path, "\\tapitask_flyout.log");
  HANDLE f = CreateFileA(path, FILE_APPEND_DATA, FILE_SHARE_READ, nullptr,
                         OPEN_ALWAYS, FILE_ATTRIBUTE_NORMAL, nullptr);
  if (f == INVALID_HANDLE_VALUE) return;
  SYSTEMTIME st;
  GetLocalTime(&st);
  char line[256];
  int n = wsprintfA(line, "[%02d:%02d:%02d.%03d] %s\r\n", st.wHour,
                    st.wMinute, st.wSecond, st.wMilliseconds, msg);
  DWORD written = 0;
  WriteFile(f, line, n, &written, nullptr);
  CloseHandle(f);
}

// Windows app theme: light unless AppsUseLightTheme says otherwise.
bool WindowsPrefersDark() {
  HKEY key;
  if (RegOpenKeyExW(
          HKEY_CURRENT_USER,
          L"Software\\Microsoft\\Windows\\CurrentVersion\\Themes\\Personalize",
          0, KEY_READ, &key) != ERROR_SUCCESS) {
    return false;
  }
  DWORD value = 1;
  DWORD size = sizeof(value);
  DWORD type = 0;
  if (RegQueryValueExW(key, L"AppsUseLightTheme", nullptr, &type,
                       (LPBYTE)&value, &size) != ERROR_SUCCESS) {
    value = 1;
  }
  RegCloseKey(key);
  return type == REG_DWORD && value == 0;
}

int Luminance(COLORREF c) {
  return (GetRValue(c) * 299 + GetGValue(c) * 587 + GetBValue(c) * 114) / 1000;
}

}  // namespace

std::wstring FlyoutWindow::ToWide(const std::string& utf8) {
  return ToWideImpl(utf8);
}
std::string FlyoutWindow::ToUtf8(const std::wstring& wide) {
  return ToUtf8Impl(wide);
}
int FlyoutWindow::ParseColor(const std::string& hex) {
  if (hex.size() != 7 || hex[0] != '#') return 0;
  int rgb = 0;
  for (char c : hex.substr(1)) {
    int v;
    if (c >= '0' && c <= '9') v = c - '0';
    else if (c >= 'a' && c <= 'f') v = c - 'a' + 10;
    else if (c >= 'A' && c <= 'F') v = c - 'A' + 10;
    else return 0;
    rgb = (rgb << 4) | v;
  }
  return RGB((rgb >> 16) & 0xFF, (rgb >> 8) & 0xFF, rgb & 0xFF);
}

FlyoutWindow::FlyoutWindow() = default;
FlyoutWindow::~FlyoutWindow() {
  if (window_) DestroyWindow(window_);
  if (font_) DeleteObject(font_);
  if (font_small_) DeleteObject(font_small_);
  if (font_icons_) DeleteObject(font_icons_);
  if (font_bold_) DeleteObject(font_bold_);
  if (bg_brush_) DeleteObject(bg_brush_);
  if (field_brush_) DeleteObject(field_brush_);
}

bool FlyoutWindow::Create(EventCallback on_event) {
  on_event_ = std::move(on_event);

  INITCOMMONCONTROLSEX icc = {};
  icc.dwSize = sizeof(icc);
  icc.dwICC = ICC_LISTVIEW_CLASSES;
  InitCommonControlsEx(&icc);

  RefreshTheme();

  WNDCLASS wc = {};
  // Force l'invalidate complet du client à chaque resize (évite les
  // fantômes de pin/open/close/title repositionnés par Layout()).
  wc.style = CS_HREDRAW | CS_VREDRAW;
  wc.lpfnWndProc = &FlyoutWindow::WndProc;
  wc.hInstance = GetModuleHandle(nullptr);
  wc.lpszClassName = kClassName;
  wc.hCursor = LoadCursor(nullptr, IDC_ARROW);
  wc.hbrBackground = bg_brush_;
  if (RegisterClass(&wc) == 0) {
    Flog("RegisterClass FAILED");
  }

  RECT work;
  SystemParametersInfo(SPI_GETWORKAREA, 0, &work, 0);
  int x = work.right - kDefaultWidth - 12;
  int y = work.bottom - kDefaultHeight - 12;

  window_ = CreateWindowEx(
      WS_EX_TOPMOST | WS_EX_TOOLWINDOW, kClassName, L"Tapitask",
      WS_POPUP | WS_THICKFRAME, x, y, kDefaultWidth, kDefaultHeight, nullptr,
      nullptr, wc.hInstance, this);
  if (!window_) {
    char msg[64];
    wsprintfA(msg, "CreateWindowEx FAILED err=%lu", GetLastError());
    Flog(msg);
    return false;
  }
  Flog("flyout window created (hidden)");

  // Windows 11 rounded corners (harmless no-op on Windows 10).
  {
    typedef HRESULT(WINAPI * DwmSetWindowAttributeFn)(
        HWND, DWORD, const void*, DWORD);
    HMODULE dwm = LoadLibraryW(L"dwmapi.dll");
    if (dwm) {
      auto set_attr = (DwmSetWindowAttributeFn)GetProcAddress(
          dwm, "DwmSetWindowAttribute");
      if (set_attr) {
        int pref = 2;  // DWMWCP_ROUND
        set_attr(window_, 33 /* DWMWA_WINDOW_CORNER_PREFERENCE */, &pref,
                 sizeof(pref));
      }
    }
  }

  font_ = CreateFontW(-15, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                      OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                      CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                      L"Segoe UI");
  font_small_ = CreateFontW(-13, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                            CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                            L"Segoe UI");
  font_icons_ = CreateFontW(-16, 0, 0, 0, FW_NORMAL, 0, 0, 0, DEFAULT_CHARSET,
                            OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                            CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                            L"Segoe MDL2 Assets");
  font_bold_ = CreateFontW(-15, 0, 0, 0, FW_SEMIBOLD, 0, 0, 0, DEFAULT_CHARSET,
                           OUT_DEFAULT_PRECIS, CLIP_DEFAULT_PRECIS,
                           CLEARTYPE_QUALITY, DEFAULT_PITCH | FF_DONTCARE,
                           L"Segoe UI");
  BuildControls();
  return true;
}

void FlyoutWindow::RefreshTheme() {
  dark_ = WindowsPrefersDark();
  if (dark_) {
    c_bg_ = RGB(32, 32, 32);
    c_text_ = RGB(240, 240, 240);
    c_subtle_ = RGB(152, 152, 152);
    c_hover_ = RGB(58, 58, 58);
    c_field_ = RGB(45, 45, 45);
  } else {
    c_bg_ = RGB(255, 255, 255);
    c_text_ = RGB(26, 26, 26);
    c_subtle_ = RGB(117, 117, 117);
    c_hover_ = RGB(238, 238, 238);
    c_field_ = RGB(248, 248, 248);
  }
  if (bg_brush_) DeleteObject(bg_brush_);
  if (field_brush_) DeleteObject(field_brush_);
  bg_brush_ = CreateSolidBrush(c_bg_);
  field_brush_ = CreateSolidBrush(c_field_);
}

void FlyoutWindow::ApplyThemeToChildren() {
  ListView_SetBkColor(items_list_, c_bg_);
  ListView_SetTextBkColor(items_list_, c_bg_);
  ListView_SetTextColor(items_list_, c_text_);
  InvalidateRect(window_, nullptr, TRUE);
}

void FlyoutWindow::BuildControls() {
  // Owner-drawn flat icon buttons (Windows 11 caption-button look).
  pin_btn_ = CreateWindowW(L"BUTTON", L"\uE718",
                           WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, 0, 0, 36, 32,
                           window_, (HMENU)(INT_PTR)1, nullptr, nullptr);
  open_btn_ = CreateWindowW(L"BUTTON", L"\uE8A6",
                            WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, 0, 0, 34,
                            30, window_, (HMENU)(INT_PTR)8, nullptr, nullptr);
  close_btn_ = CreateWindowW(L"BUTTON", L"\uE711",
                              WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, 0, 0, 36,
                              32, window_, (HMENU)(INT_PTR)2, nullptr,
                              nullptr);
  title_ = CreateWindowW(L"STATIC", L"Tapitask",
                         WS_CHILD | WS_VISIBLE | SS_NOPREFIX, 0, 0, 120, 30,
                         window_, (HMENU)(INT_PTR)7, nullptr, nullptr);
  // LVS_OWNERDRAWFIXED : les lignes sont dessinées à la main (DrawListItem)
  // — le badge d'échéance est en gras sans puce ajoutée par le rendu
  // standard (correction de la puce doublée).
  items_list_ = CreateWindowExW(
      0, WC_LISTVIEWW, L"",
      WS_CHILD | WS_VISIBLE | WS_TABSTOP | WS_VSCROLL | LVS_REPORT |
          LVS_NOCOLUMNHEADER | LVS_SINGLESEL | LVS_OWNERDRAWFIXED,
      0, 0, 100, 100, window_, (HMENU)(INT_PTR)3, nullptr, nullptr);
  ListView_SetExtendedListViewStyle(items_list_,
                                    LVS_EX_CHECKBOXES | LVS_EX_FULLROWSELECT);
  quick_add_ = CreateWindowExW(0, L"EDIT", L"",
                               WS_CHILD | WS_VISIBLE | WS_TABSTOP |
                                   ES_MULTILINE | ES_WANTRETURN |
                                   ES_AUTOVSCROLL,
                               0, 0, 100, 48, window_, (HMENU)(INT_PTR)4,
                               nullptr, nullptr);
  add_btn_ = CreateWindowW(L"BUTTON", L"\uE710",
                           WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, 0, 0, 40, 34,
                           window_, (HMENU)(INT_PTR)5, nullptr, nullptr);
  status_ = CreateWindowW(L"STATIC", L"",
                          WS_CHILD | WS_VISIBLE | SS_CENTER | SS_NOPREFIX, 0,
                          0, 100, 20, window_, (HMENU)(INT_PTR)6, nullptr,
                          nullptr);

  SendMessage(pin_btn_, WM_SETFONT, (WPARAM)font_icons_, TRUE);
  SendMessage(open_btn_, WM_SETFONT, (WPARAM)font_icons_, TRUE);
  SendMessage(close_btn_, WM_SETFONT, (WPARAM)font_icons_, TRUE);
  SendMessage(add_btn_, WM_SETFONT, (WPARAM)font_icons_, TRUE);
  SendMessage(items_list_, WM_SETFONT, (WPARAM)font_, TRUE);
  SendMessage(quick_add_, WM_SETFONT, (WPARAM)font_, TRUE);
  SendMessage(title_, WM_SETFONT, (WPARAM)font_bold_, TRUE);
  SendMessage(status_, WM_SETFONT, (WPARAM)font_small_, TRUE);

  LVCOLUMN col = {};
  col.mask = LVCF_WIDTH;
  col.cx = 600;
  ListView_InsertColumn(items_list_, 0, &col);

  // Subclass every control: Esc closes, Ctrl+Enter validates, hover tracking
  // for the owner-drawn buttons.
  default_edit_proc_ = (WNDPROC)SetWindowLongPtr(
      quick_add_, GWLP_WNDPROC, (LONG_PTR)&FlyoutWindow::SubProc);
  default_list_proc_ = (WNDPROC)SetWindowLongPtr(
      items_list_, GWLP_WNDPROC, (LONG_PTR)&FlyoutWindow::SubProc);
  SetWindowLongPtr(quick_add_, GWLP_USERDATA, (LONG_PTR)this);
  SetWindowLongPtr(items_list_, GWLP_USERDATA, (LONG_PTR)this);
  for (HWND btn : {pin_btn_, open_btn_, close_btn_, add_btn_}) {
    default_btn_proc_ = (WNDPROC)SetWindowLongPtr(
        btn, GWLP_WNDPROC, (LONG_PTR)&FlyoutWindow::SubProc);
    SetWindowLongPtr(btn, GWLP_USERDATA, (LONG_PTR)this);
  }
  ApplyThemeToChildren();
}

void FlyoutWindow::Show(bool pinned) {
  pinned_ = pinned;
  Flog("Show() requested");
  RECT rc;
  GetClientRect(window_, &rc);
  Layout(rc.right, rc.bottom);
  SetWindowPos(window_, pinned_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
               SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
  // Standard tray-flyout pattern: the user just clicked OUR tray icon, so
  // Windows grants the process the foreground right. Taking it BEFORE
  // showing lets the popup become the active window; without this the
  // foreground-lock denies activation and the dismiss-on-focus-loss handler
  // re-hides the window in the same frame.
  SetForegroundWindow(window_);
  ShowWindow(window_, SW_SHOW);
  SetActiveWindow(window_);
  visible_ = true;
  shown_tick_ = GetTickCount();
  SetFocus(quick_add_);
  Flog("Show() done");
}

void FlyoutWindow::Hide() {
  Flog("Hide()");
  ShowWindow(window_, SW_HIDE);
  visible_ = false;
}

void FlyoutWindow::UpdateData(const std::string& payload) {
  lists_.clear();
  items_.clear();
  bool active_set = false;
  size_t pos = 0;
  while (pos < payload.size()) {
    size_t eol = payload.find('\n', pos);
    if (eol == std::string::npos) eol = payload.size();
    std::string line = payload.substr(pos, eol - pos);
    pos = eol + 1;
    if (line.size() < 3 || line[1] != '\t') continue;
    char kind = line[0];
    std::string rest = line.substr(2);
    auto tab1 = rest.find('\t');
    if (kind == 'L') {
      if (tab1 == std::string::npos) continue;
      std::string id = rest.substr(0, tab1);
      std::string rest2 = rest.substr(tab1 + 1);
      auto tab2 = rest2.find('\t');
      if (tab2 == std::string::npos) continue;
      lists_.push_back(ListInfo{id, rest2.substr(0, tab2),
                                ParseColor(rest2.substr(tab2 + 1))});
    } else if (kind == 'A') {
      active_ = rest;
      active_set = true;
    } else if (kind == 'F') {
      // Fine-grained flyout setting: open-app button visibility (1/0).
      show_open_ = rest != "0";
      if (open_btn_) {
        ShowWindow(open_btn_, show_open_ ? SW_SHOW : SW_HIDE);
      }
    } else if (kind == 'T') {
      // Localized labels: add \t delete \t empty \t no-lists
      auto field = [&](int n) {
        std::string v = rest;
        for (int i = 0; i < n && !v.empty(); i++) {
          auto t = v.find('\t');
          if (t == std::string::npos) return std::string();
          v = v.substr(t + 1);
        }
        auto end = v.find('\t');
        return end == std::string::npos ? v : v.substr(0, end);
      };
      delete_label_ = ToWide(field(1));
      empty_label_ = ToWide(field(2));
      no_lists_label_ = ToWide(field(3));
    } else if (kind == 'I') {
      if (tab1 == std::string::npos) continue;
      std::string id = rest.substr(0, tab1);
      std::string rest2 = rest.substr(tab1 + 1);
      auto tab2 = rest2.find('\t');
      if (tab2 == std::string::npos) continue;
      // Optional 4th field: localized due-date badge.
      std::string label = rest2.substr(tab2 + 1);
      std::string due;
      auto tab3 = label.find('\t');
      if (tab3 != std::string::npos) {
        due = label.substr(tab3 + 1);
        label = label.substr(0, tab3);
      }
      items_.push_back(ItemInfo{id, rest2.substr(0, tab2) == "1", label, due});
    }
  }
  if (!active_set && !lists_.empty()) active_ = lists_.front().id;
  RebuildItems();
  if (visible_) {
    RECT rc;
    GetClientRect(window_, &rc);
    Layout(rc.right, rc.bottom);
  }
}

void FlyoutWindow::RebuildChips(int width) {
  // C2.5 : pas de destruction/recréation des chips à chaque WM_SIZE —
  // seulement si la largeur traitée a changé (ou si le jeu de listes a
  // changé, via UpdateData).
  size_t sig = 1469598103934665603ull;
  for (const auto& l : lists_) {
    for (unsigned char c : l.id) {
      sig ^= c;
      sig *= 1099511628211ull;
    }
  }
  if (width == last_chip_width_ && sig == last_chip_sig_) {
    // L'actif a changé à seul (sig/width identiques) : on invalide les
    // chips existants, pas de destruction/recréation.
    if (active_ != last_chip_active_) {
      last_chip_active_ = active_;
      for (HWND chip : chips_) InvalidateRect(chip, nullptr, TRUE);
    }
    return;
  }
  last_chip_width_ = width;
  last_chip_sig_ = sig;
  for (HWND chip : chips_) {
    hover_.erase(chip);
    DestroyWindow(chip);
  }
  chips_.clear();
  // A single pinned list needs no chip — the user knows what they see.
  if (lists_.size() <= 1) {
    chips_rows_ = 0;
    last_chip_active_ = active_;
    return;
  }
  int x = 8;
  int y = 44;
  chips_rows_ = 1;
  for (const auto& list : lists_) {
    std::wstring label = ToWide(list.title);
    HDC dc = GetDC(window_);
    SelectObject(dc, font_small_);
    SIZE sz = {};
    GetTextExtentPoint32W(dc, label.c_str(), (int)label.size(), &sz);
    ReleaseDC(window_, dc);
    int w = std::min<int>(150, static_cast<int>(sz.cx) + 28);
    HWND chip = CreateWindowW(
        L"BUTTON", label.c_str(), WS_CHILD | WS_VISIBLE | BS_OWNERDRAW, x, y,
        w, 28, window_, (HMENU)(UINT_PTR)(100 + chips_.size()), nullptr,
        nullptr);
    SendMessage(chip, WM_SETFONT, (WPARAM)font_small_, TRUE);
    default_btn_proc_ = (WNDPROC)SetWindowLongPtr(
        chip, GWLP_WNDPROC, (LONG_PTR)&FlyoutWindow::SubProc);
    SetWindowLongPtr(chip, GWLP_USERDATA, (LONG_PTR)this);
    chips_.push_back(chip);
    x += w + 6;
    if (x > width - 150 && &list != &lists_.back()) {
      x = 8;
      y += 32;
      chips_rows_++;
    }
  }
  last_chip_active_ = active_;
}

void FlyoutWindow::RebuildItems() {
  suppress_check_events_ = true;
  ListView_DeleteAllItems(items_list_);
  int i = 0;
  for (const auto& item : items_) {
    // Texte brut : le badge (gras, puce une seule fois) est dessiné par
    // DrawListItem — plus de concaténation ici.
    std::wstring label = ToWide(item.label);
    LVITEMW it = {};
    it.mask = LVIF_TEXT;
    it.iItem = i;
    it.pszText = (LPWSTR)label.c_str();
    ListView_InsertItem(items_list_, &it);
    ListView_SetCheckState(items_list_, i, item.done ? TRUE : FALSE);
    i++;
  }
  suppress_check_events_ = false;
  if (items_.empty()) {
    SetWindowTextW(status_,
                   lists_.empty() ? no_lists_label_.c_str()
                                  : empty_label_.c_str());
    ShowWindow(status_, SW_SHOW);
    ShowWindow(items_list_, SW_HIDE);
  } else {
    ShowWindow(status_, SW_HIDE);
    ShowWindow(items_list_, SW_SHOW);
  }
}

void FlyoutWindow::Layout(int width, int height) {
  const int margin = 10;
  int y = 6;
  MoveWindow(pin_btn_, margin, y, 34, 30, TRUE);
  MoveWindow(close_btn_, width - 34 - margin, y, 34, 30, TRUE);
  MoveWindow(open_btn_, width - 34 - margin - 36, y, 34, 30, TRUE);
  MoveWindow(title_, margin + 40, y + 3, width - 2 * margin - 118, 26, TRUE);
  y += 38;
  RebuildChips(width);
  y += chips_rows_ > 0 ? chips_rows_ * 32 : 4;
  int edit_h = 54;
  int add_h = 34;
  int list_h = height - y - edit_h - 2 * margin;
  if (list_h < 40) list_h = 40;
  MoveWindow(items_list_, margin, y, width - 2 * margin, list_h, TRUE);
  MoveWindow(status_, margin, y, width - 2 * margin, list_h, TRUE);
  // The single column must match the client width, otherwise the ListView
  // shows a useless horizontal scrollbar.
  ListView_SetColumnWidth(items_list_, 0, width - 2 * margin - 6);
  y += list_h + margin;
  MoveWindow(quick_add_, margin, y, width - 2 * margin - 44 - 6, edit_h,
             TRUE);
  MoveWindow(add_btn_, width - 40 - margin, y + (edit_h - add_h) / 2, 40,
             add_h, TRUE);
}

// ---- Owner-draw painting (the Windows 11 look, by hand) ----

void FlyoutWindow::DrawIconButton(const DRAWITEMSTRUCT* dis,
                                  const wchar_t* glyph,
                                  COLORREF glyph_color) {
  HDC dc = dis->hDC;
  RECT rc = dis->rcItem;
  bool hovered = hover_[dis->hwndItem];
  bool pressed = (dis->itemState & ODS_SELECTED) != 0;
  // Rounded hover/pressed background, transparent otherwise.
  COLORREF bg = pressed ? (dark_ ? RGB(45, 45, 45) : RGB(230, 230, 230))
               : hovered ? c_hover_
                         : c_bg_;
  HBRUSH brush = CreateSolidBrush(bg);
  HPEN pen = CreatePen(PS_SOLID, 1, bg);
  HGDIOBJ old_brush = SelectObject(dc, brush);
  HGDIOBJ old_pen = SelectObject(dc, pen);
  RoundRect(dc, rc.left, rc.top, rc.right, rc.bottom, 8, 8);
  SelectObject(dc, old_brush);
  SelectObject(dc, old_pen);
  DeleteObject(brush);
  DeleteObject(pen);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, glyph_color);
  HGDIOBJ old_font = SelectObject(dc, font_icons_);
  DrawTextW(dc, glyph, -1, &rc, DT_CENTER | DT_VCENTER | DT_SINGLELINE);
  SelectObject(dc, old_font);
}

void FlyoutWindow::DrawChip(const DRAWITEMSTRUCT* dis, const ListInfo& list,
                            bool active) {
  HDC dc = dis->hDC;
  RECT rc = dis->rcItem;
  bool hovered = hover_[dis->hwndItem];
  bool pressed = (dis->itemState & ODS_SELECTED) != 0;
  COLORREF accent = dark_ ? RGB(96, 205, 255) : RGB(0, 120, 212);
  COLORREF fill;
  COLORREF text;
  if (active && list.color != 0) {
    fill = list.color;
    text = Luminance(list.color) > 150 ? RGB(20, 20, 20) : RGB(255, 255, 255);
  } else if (active) {
    fill = accent;
    text = RGB(255, 255, 255);
  } else {
    fill = pressed ? c_hover_ : (hovered ? c_hover_ : c_field_);
    text = c_text_;
  }
  HBRUSH brush = CreateSolidBrush(fill);
  HPEN pen = CreatePen(PS_SOLID, 1, fill);
  HGDIOBJ old_brush = SelectObject(dc, brush);
  HGDIOBJ old_pen = SelectObject(dc, pen);
  // Pill shape.
  RoundRect(dc, rc.left, rc.top, rc.right, rc.bottom,
            rc.bottom - rc.top, rc.bottom - rc.top);
  SelectObject(dc, old_brush);
  SelectObject(dc, old_pen);
  DeleteObject(brush);
  DeleteObject(pen);
  int len = GetWindowTextLengthW(dis->hwndItem);
  std::wstring label(len, L'\0');
  GetWindowTextW(dis->hwndItem, (LPWSTR)label.data(), len + 1);
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, text);
  HGDIOBJ old_font = SelectObject(dc, font_small_);
  RECT text_rc = rc;
  text_rc.left += 6;
  DrawTextW(dc, label.c_str(), -1, &text_rc,
            DT_CENTER | DT_VCENTER | DT_SINGLELINE | DT_END_ELLIPSIS);
  SelectObject(dc, old_font);
}

void FlyoutWindow::DrawListItem(const DRAWITEMSTRUCT* dis) {
  int idx = (int)dis->itemID;
  if (items_list_ == nullptr || idx < 0 || idx >= (int)items_.size()) return;
  const auto& item = items_[idx];
  HDC dc = dis->hDC;
  RECT rc = dis->rcItem;
  const bool selected = (dis->itemState & ODS_SELECTED) != 0;
  // C2.5 : le fond est TOUTEFOIS peint (accent quand sélectionné, bg sinon)
  // — le brush de classe seul laisse des traînées à la désélection.
  const COLORREF row_bg = selected ? (dark_ ? RGB(96, 205, 255) : RGB(0, 120, 212))
                                   : c_bg_;
  HBRUSH brush = CreateSolidBrush(row_bg);
  FillRect(dc, &rc, brush);
  DeleteObject(brush);
  const COLORREF text = selected ? RGB(255, 255, 255) : c_text_;
  // Case (check state), à la position d'avant — dessinée par l'owner car
  // le contrôle ne dessine plus rien en mode OWNERDRAWFIXED.
  RECT brc = CheckboxRectFor(rc);
  DrawFrameControl(dc, &brc, DFC_BUTTON,
                   DFCS_BUTTONCHECK |
                       (ListView_GetCheckState(items_list_, idx) ? DFCS_CHECKED
                                                                 : 0));
  // Badge d'échéance à droite, en gras, dans le même run « •  <due> » —
  // la puce est ajoutée une seule fois ici (celle du retard vient de l10n).
  const std::wstring due = ToWide(item.due);
  int due_w = 0;
  std::wstring due_run;
  if (!due.empty()) {
    // Le retard arrive avec sa puce l10n (« •  en retard ») : on ne
    // préfixe une puce que si due n'en contient pas (échéance future).
    due_run = due.find(L"\u2022") == std::wstring::npos ? L"  \u2022  " + due
                                                        : due;
    HGDIOBJ old_font = SelectObject(dc, font_bold_);
    SIZE sz = {};
    GetTextExtentPoint32W(dc, due_run.c_str(), (int)due_run.size(), &sz);
    SelectObject(dc, old_font);
    due_w = sz.cx + 4;
  }
  // C2.5 : le run due ne chevauche JAMAIS la case à cocher, même fenêtre
  // étroite : drc.left = max(fin de la case + padding, droite - due_w).
  const int due_left =
      due_w > 0 ? std::max(rc.right - due_w, brc.right + 2) : rc.right;
  SetBkMode(dc, TRANSPARENT);
  SetTextColor(dc, text);
  // Label : ellipsis-friendly comme avant (DT_PATH_ELLIPSIS), en font_.
  RECT lrc = rc;
  lrc.left = brc.right + 2;
  if (due_w > 0) lrc.right = due_left;
  HGDIOBJ old_font = SelectObject(dc, font_);
  DrawTextW(dc, ToWide(item.label).c_str(), -1, &lrc,
            DT_SINGLELINE | DT_PATH_ELLIPSIS);
  // Le run due peut être tronqué s'il dépasse la largeur restante.
  if (due_w > 0) {
    RECT drc = rc;
    drc.left = due_left;
    SelectObject(dc, font_bold_);
    DrawTextW(dc, due_run.c_str(), -1, &drc, DT_SINGLELINE | DT_END_ELLIPSIS);
  }
  SelectObject(dc, old_font);
}

RECT FlyoutWindow::CheckboxRectFor(const RECT& item_rect) const {
  // Rect exact de la case à cocher dessinée par DrawListItem, pour un item
  // dont le rect ligne (coords client) est `item_rect`. Centrée
  // verticalement, 16px, offset gauche +2 — IDENTIQUE à DrawListItem.
  const int box = 16;
  const int box_top =
      item_rect.top + (item_rect.bottom - item_rect.top - box) / 2;
  return {item_rect.left + 2, box_top, item_rect.left + 2 + box,
          box_top + box};
}

void FlyoutWindow::DoQuickAdd() {
  int len = GetWindowTextLengthW(quick_add_);
  std::wstring text(len, L'\0');
  GetWindowTextW(quick_add_, (LPWSTR)text.data(), len + 1);
  if (!text.empty()) {
    SendEvent("add", ToUtf8(text));
    SetWindowTextW(quick_add_, L"");
  }
}

void FlyoutWindow::SendEvent(const std::string& action, const std::string& a,
                            const std::string& b) {
  if (on_event_) on_event_(action, a, b);
}

LRESULT FlyoutWindow::SubProc(HWND hwnd, UINT message, WPARAM wparam,
                              LPARAM lparam) noexcept {
  FlyoutWindow* self = (FlyoutWindow*)GetWindowLongPtr(hwnd, GWLP_USERDATA);
  if (self) {
    if (message == WM_MOUSEMOVE) {
      // Hover tracking for owner-drawn buttons (chips included).
      if (self->hover_.find(hwnd) != self->hover_.end() ||
          hwnd == self->pin_btn_ || hwnd == self->close_btn_ ||
          hwnd == self->add_btn_) {
        if (!self->hover_[hwnd]) {
          TRACKMOUSEEVENT tme = {};
          tme.cbSize = sizeof(tme);
          tme.dwFlags = TME_LEAVE;
          tme.hwndTrack = hwnd;
          TrackMouseEvent(&tme);
          self->hover_[hwnd] = true;
          InvalidateRect(hwnd, nullptr, TRUE);
        }
      }
    } else if (message == WM_MOUSELEAVE) {
      if (self->hover_[hwnd]) {
        self->hover_[hwnd] = false;
        InvalidateRect(hwnd, nullptr, TRUE);
      }
    } else if (message == WM_KEYDOWN && wparam == VK_RETURN &&
               (GetKeyState(VK_CONTROL) & 0x8000) != 0) {
      // Ctrl+Enter validates the quick-add (Enter alone = newline, for
      // multi-line batch entry).
      if (hwnd == self->quick_add_) {
        self->DoQuickAdd();
        return 0;
      }
    } else if (message == WM_KEYDOWN && wparam == VK_ESCAPE) {
      self->Hide();
      self->SendEvent("close");
      return 0;
    }
  }
  if (!self) return DefWindowProc(hwnd, message, wparam, lparam);
  WNDPROC def;
  if (hwnd == self->quick_add_) {
    def = self->default_edit_proc_;
  } else if (hwnd == self->items_list_) {
    def = self->default_list_proc_;
  } else {
    def = self->default_btn_proc_;
  }
  return CallWindowProc(def, hwnd, message, wparam, lparam);
}

LRESULT FlyoutWindow::MessageHandler(HWND hwnd, UINT message, WPARAM wparam,
                                     LPARAM lparam) {
  switch (message) {
    case WM_ACTIVATE: {
      WORD state = LOWORD(wparam);
      if (state == WA_INACTIVE) {
        Flog("WM_ACTIVATE inactive");
        // Dismiss on focus loss (native tray-popup behaviour) unless pinned.
        // Grace period: ignore activation churn right after Show().
        if (!pinned_ && GetTickCount() - shown_tick_ > 400) {
          Hide();
          SendEvent("close");
        }
      } else {
        Flog("WM_ACTIVATE active");
      }
      return 0;
    }
    case WM_SETTINGCHANGE:
      // Windows theme switched light <-> dark: follow it live.
      if (lparam != 0 && wcscmp((const wchar_t*)lparam, L"ImmersiveColorSet") == 0) {
        RefreshTheme();
        ApplyThemeToChildren();
        if (bg_brush_) SetClassLongPtr(hwnd, GCLP_HBRBACKGROUND,
                                       (LONG_PTR)bg_brush_);
      }
      return 0;
    case WM_ERASEBKGND: {
      HDC dc = (HDC)wparam;
      RECT rc;
      GetClientRect(hwnd, &rc);
      FillRect(dc, &rc, bg_brush_);
      return 1;
    }
    case WM_NCHITTEST: {
      // Drag anywhere in the header strip (top 40 px).
      LRESULT hit = DefWindowProc(hwnd, message, wparam, lparam);
      if (hit == HTCLIENT) {
        POINT pt = {GET_X_LPARAM(lparam), GET_Y_LPARAM(lparam)};
        ScreenToClient(hwnd, &pt);
        if (pt.y < 40) return HTCAPTION;
      }
      return hit;
    }
    case WM_SIZE: {
      // During CreateWindowEx the controls don't exist yet — nothing to do.
      if (!pin_btn_) return 0;
      RECT rc;
      GetClientRect(hwnd, &rc);
      Layout(rc.right, rc.bottom);
      return 0;
    }
    case WM_DRAWITEM: {
      auto* dis = (DRAWITEMSTRUCT*)lparam;
      COLORREF accent = dark_ ? RGB(96, 205, 255) : RGB(0, 120, 212);
      if (dis->CtlID == 1) {  // pin
        DrawIconButton(dis, L"\uE718", pinned_ ? accent : c_subtle_);
        return TRUE;
      }
      if (dis->CtlID == 8) {  // open app
        DrawIconButton(dis, L"\uE8A6", c_subtle_);
        return TRUE;
      }
      if (dis->CtlID == 2) {  // close
        DrawIconButton(dis, L"\uE711", c_subtle_);
        return TRUE;
      }
      if (dis->CtlID == 5) {  // add (icon-only ＋)
        DrawIconButton(dis, L"\uE710", accent);
        return TRUE;
      }
      if (dis->CtlID >= 100) {  // chips
        size_t idx = dis->CtlID - 100;
        if (idx < lists_.size()) {
          DrawChip(dis, lists_[idx], lists_[idx].id == active_);
        }
        return TRUE;
      }
      if (dis->CtlID == 3 && dis->hwndItem == items_list_) {  // items
        DrawListItem(dis);
        return TRUE;
      }
      return TRUE;
    }
    case WM_COMMAND: {
      WORD id = LOWORD(wparam);
      if (id == 2) {  // close
        Hide();
        SendEvent("close");
      } else if (id == 8) {  // open app
        Hide();
        SendEvent("openApp");
      } else if (id == 1) {  // pin
        pinned_ = !pinned_;
        SetWindowPos(hwnd, pinned_ ? HWND_TOPMOST : HWND_NOTOPMOST, 0, 0, 0, 0,
                     SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        InvalidateRect(pin_btn_, nullptr, TRUE);
        SendEvent("pin", pinned_ ? "true" : "false");
      } else if (id == 5) {  // add
        DoQuickAdd();
      } else if (id >= 100) {  // chips
        size_t idx = id - 100;
        if (idx < lists_.size()) SendEvent("select", lists_[idx].id);
      }
      return 0;
    }
    case WM_NOTIFY: {
      auto* nm = (NMHDR*)lparam;
      if (nm->hwndFrom == items_list_) {
        if (nm->code == LVN_ITEMCHANGED) {
          auto* nmlv = (NMLISTVIEW*)lparam;
          if ((nmlv->uNewState & LVIS_STATEIMAGEMASK) != 0 &&
              !suppress_check_events_) {
            if (nmlv->iItem >= 0 && nmlv->iItem < (int)items_.size()) {
              BOOL checked =
                  ListView_GetCheckState(items_list_, nmlv->iItem);
              if ((checked != FALSE) != items_[nmlv->iItem].done) {
                SendEvent(checked ? "check" : "uncheck",
                          items_[nmlv->iItem].id);
              }
            }
          }
        } else if (nm->code == NM_CLICK) {
          const auto* click = reinterpret_cast<NMITEMACTIVATE*>(lparam);
          LVHITTESTINFO hit = {};
          hit.pt = click->ptAction;
          const int index = ListView_HitTest(items_list_, &hit);
          if (index >= 0 && index < static_cast<int>(items_.size())) {
            RECT item_rect = {};
            ListView_GetItemRect(items_list_, index, &item_rect,
                                 LVIR_BOUNDS);
            RECT box = CheckboxRectFor(item_rect);
            if (PtInRect(&box, click->ptAction)) {
              // Clic précis sur la case : toggle manuel, le natif est
              // peu fiable avec LVS_EX_FULLROWSELECT (cf. spec).
              BOOL was_checked = ListView_GetCheckState(items_list_, index);
              ListView_SetCheckState(items_list_, index, !was_checked);
              // ListView_SetCheckState déclenche LVN_ITEMCHANGED → le
              // handler existant (suppress_check_events_, comparaison à
              // items_[index].done) envoie check/uncheck — rien à
              // dupliquer ici.
            } else {
              Hide();
              SendEvent("openTask", items_[index].id);
            }
          }
        } else if (nm->code == NM_RCLICK) {
          // Right-click -> Supprimer.
          POINT pt;
          GetCursorPos(&pt);
          HMENU menu = CreatePopupMenu();
          AppendMenuW(menu, MF_STRING, 1, delete_label_.c_str());
          int sel = ListView_GetNextItem(items_list_, -1, LVNI_SELECTED);
          if (sel >= 0 && sel < (int)items_.size()) {
            int cmd = TrackPopupMenu(menu, TPM_RETURNCMD, pt.x, pt.y, 0, hwnd,
                                     nullptr);
            if (cmd == 1) SendEvent("delete", items_[sel].id);
          }
          DestroyMenu(menu);
        }
      }
      return 0;
    }
    case WM_CTLCOLORSTATIC: {
      HDC dc = (HDC)wparam;
      SetBkMode(dc, TRANSPARENT);
      SetTextColor(dc, (HWND)lparam == status_ ? c_subtle_ : c_text_);
      return (LRESULT)bg_brush_;
    }
    case WM_CTLCOLOREDIT: {
      // Modern input field: soft background, no 3D border.
      HDC dc = (HDC)wparam;
      SetBkColor(dc, c_field_);
      SetTextColor(dc, c_text_);
      return (LRESULT)field_brush_;
    }
    default:
      return DefWindowProc(hwnd, message, wparam, lparam);
  }
}

LRESULT CALLBACK FlyoutWindow::WndProc(HWND hwnd, UINT message, WPARAM wparam,
                                       LPARAM lparam) noexcept {
  if (message == WM_NCCREATE) {
    auto* cs = (CREATESTRUCT*)lparam;
    SetWindowLongPtr(hwnd, GWLP_USERDATA, (LONG_PTR)cs->lpCreateParams);
  }
  FlyoutWindow* self = (FlyoutWindow*)GetWindowLongPtr(hwnd, GWLP_USERDATA);
  if (self) return self->MessageHandler(hwnd, message, wparam, lparam);
  return DefWindowProc(hwnd, message, wparam, lparam);
}
