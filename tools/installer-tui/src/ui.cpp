#include "ui.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <string>
#include <thread>
#include <vector>

#include <unistd.h>

#include "ftxui/component/component.hpp"
#include "ftxui/component/event.hpp"
#include "ftxui/component/screen_interactive.hpp"
#include "ftxui/dom/elements.hpp"

#include "engine.hpp"

namespace installer {
namespace {

using namespace ftxui;

// 去掉 ANSI 颜色序列（setup.sh 非 TTY 下仍可能输出颜色），避免日志面板显示原始码
std::string StripAnsi(const std::string& s) {
  std::string out;
  out.reserve(s.size());
  for (size_t i = 0; i < s.size();) {
    if (s[i] == '\x1b' && i + 1 < s.size() && s[i + 1] == '[') {
      size_t j = i + 2;
      while (j < s.size() &&
             !((s[j] >= 'a' && s[j] <= 'z') || (s[j] >= 'A' && s[j] <= 'Z'))) {
        ++j;
      }
      i = (j < s.size()) ? j + 1 : j;
    } else {
      out.push_back(s[i]);
      ++i;
    }
  }
  return out;
}

// 按 UTF-8 安全边界截断到字节上限（不撕裂多字节字符）
std::string TruncateUtf8(const std::string& s, size_t max_bytes) {
  if (s.size() <= max_bytes) return s;
  size_t end = max_bytes;
  while (end > 0 && (static_cast<unsigned char>(s[end]) & 0xC0) == 0x80) --end;
  return s.substr(0, end) + "...";
}

// 布尔槽：std::vector<bool> 的 operator[] 返回代理引用，无法给 FTXUI 当 bool*，
// 故用带真 bool 成员的结构体。
struct BoolSlot {
  bool value = false;
};

// 日志面板最多显示的行数（只渲染尾部）
constexpr size_t kLogTail = 40;
constexpr size_t kLogMax = 2000;

// 执行引擎：选择状态 + 日志缓冲 + 后台子进程。
// 所有 UI 状态（选择、日志）只在主线程读写；worker 通过 App::Post 投递更新，
// 因此无需互斥锁（FTXUI 的 Post 线程安全）。退出前等待 worker 结束。
class Runner {
 public:
  Runner(const std::filesystem::path& repo_root, const Manifest& manifest)
      : repo_root_(repo_root),
        manifest_(manifest),
        skills_selected(manifest.skills.size()),
        plugins_selected(manifest.plugins.size()),
        uninstall_selected(manifest.skills.size() + manifest.plugins.size()) {}

  // 选择状态（绑定到 Checkbox 的 bool*，由 FTXUI 读写）
  std::vector<BoolSlot> skills_selected;
  std::vector<BoolSlot> plugins_selected;
  std::vector<BoolSlot> uninstall_selected;

  // 日志缓冲（仅主线程访问）
  std::vector<std::string> log_entries;

  // 后台子进程运行中标记
  std::atomic<bool> running{false};
  std::atomic<bool> cancel_requested{false};
  std::atomic<int> last_rc{0};

  int SelectedSkillCount() const {
    return static_cast<int>(std::count_if(
        skills_selected.begin(), skills_selected.end(),
        [](const BoolSlot& s) { return s.value; }));
  }
  int SelectedPluginCount() const {
    return static_cast<int>(std::count_if(
        plugins_selected.begin(), plugins_selected.end(),
        [](const BoolSlot& s) { return s.value; }));
  }

  // worker → 主线程：追加一行日志并请求重绘（Post 线程安全）
  void PushLine(const std::string& raw) {
    App* app = App::Active();
    if (!app) return;
    const std::string clean = StripAnsi(raw);
    app->Post([this, clean] {
      log_entries.push_back(clean);
      if (log_entries.size() > kLogMax) log_entries.erase(log_entries.begin());
      if (App::Active()) App::Active()->RequestAnimationFrame();
    });
  }

  // 在后台线程运行 setup.sh；running 期间拒绝并发执行
  void Spawn(std::vector<std::string> args, const std::string& label) {
    if (running.exchange(true)) return;  // 已在运行，忽略
    if (worker_.joinable()) worker_.join();
    cancel_requested = false;
    last_rc = 1;
    PushLine("==> " + label);
    worker_ = std::thread([this, args = std::move(args)] {
      auto on_line = [this](const std::string& l) { PushLine(l); };
      last_rc = RunSetup(repo_root_, args, on_line, &cancel_requested);
      PushLine(last_rc == 0 ? "==> 完成 (退出码 0)"
                            : "==> 失败 (退出码 " + std::to_string(last_rc.load()) + ")");
      running = false;
    });
  }

  // 取消后台子进程并等待 worker 回收 setup 子进程。
  int CancelAndWait() {
    const bool was_running = running.load();
    if (was_running) cancel_requested = true;
    if (worker_.joinable()) worker_.join();
    return was_running ? 0 : last_rc.load();
  }

  // 等待后台子进程结束（正常退出 TUI 前调用，避免 App 析构后 worker 仍 Post）
  int Wait() {
    if (worker_.joinable()) worker_.join();
    return last_rc.load();
  }

 private:
  const std::filesystem::path& repo_root_;
  const Manifest& manifest_;
  std::thread worker_;
};

// 依据当前勾选构造安装 argv。
// 两类都未勾选 = 全量安装（--ci 不带 skip）；仅选其一 = 带 --skip-*。
std::vector<std::string> BuildInstallArgs(const Manifest& m, const Runner& r) {
  std::vector<std::string> args = {"install", "--ci"};
  const int sk = r.SelectedSkillCount();
  const int pk = r.SelectedPluginCount();
  if (sk == 0 && pk == 0) return args;
  if (sk == 0) {
    args.push_back("--skip-skills");
  } else {
    for (size_t i = 0; i < m.skills.size(); ++i)
      if (r.skills_selected[i].value) {
        args.push_back("--skill");
        args.push_back(m.skills[i].name);
      }
  }
  if (pk == 0) {
    args.push_back("--skip-plugins");
  } else {
    for (size_t i = 0; i < m.plugins.size(); ++i)
      if (r.plugins_selected[i].value) {
        args.push_back("--plugin");
        args.push_back(m.plugins[i].name);
      }
  }
  return args;
}

// UI 状态：跨组件树共享，存活于 RunUi 生命周期
struct UiState {
  int tab_selected = 0;    // 0=Install 1=Update 2=Uninstall
  int update_mode = 0;     // 0=全部 1=选中项
  int uninstall_mode = 0;  // 0=全部 1=core 2=选中项
  bool show_modal = false;
  std::string confirm_text;
};

// 日志面板：纯展示 Renderer，不参与焦点，显示尾部 kLogTail 行
Component MakeLogView(Runner* runner) {
  return Renderer([runner] {
    Elements els;
    if (runner->log_entries.empty()) {
      els.push_back(text("（暂无日志，按 [e] 执行后显示）") | dim);
    } else {
      const size_t start =
          runner->log_entries.size() > kLogTail ? runner->log_entries.size() - kLogTail : 0;
      for (size_t i = start; i < runner->log_entries.size(); ++i) {
        els.push_back(text(runner->log_entries[i]));
      }
    }
    return vbox(std::move(els)) | frame | flex;
  });
}

// 顶部 tab 指示（纯文本）
Component MakeTabIndicator(UiState* state) {
  return Renderer([state] {
    Elements cells;
    const char* names[] = {"1 Install", "2 Update", "3 Uninstall"};
    for (int i = 0; i < 3; ++i) {
      cells.push_back(text(names[i]) | (i == state->tab_selected ? bold : dim));
      cells.push_back(text("   "));
    }
    return hbox(cells) | center;
  });
}

}  // namespace

int RunUi(const std::filesystem::path& repo_root, const Manifest& manifest,
          int execution_fd) {
  Runner runner(repo_root, manifest);
  UiState state;

  // ---- Install 页：skills 与 plugins 两列 Checkbox ----
  Components skill_cols, plugin_cols;
  for (size_t i = 0; i < manifest.skills.size(); ++i) {
    skill_cols.push_back(Checkbox(manifest.skills[i].name + "  " +
                                      TruncateUtf8(manifest.skills[i].note, 36),
                                  &runner.skills_selected[i].value));
  }
  for (size_t i = 0; i < manifest.plugins.size(); ++i) {
    plugin_cols.push_back(Checkbox(manifest.plugins[i].name + "  " +
                                       TruncateUtf8(manifest.plugins[i].note, 36),
                                   &runner.plugins_selected[i].value));
  }
  auto skill_col = Container::Vertical(std::move(skill_cols));
  auto plugin_col = Container::Vertical(std::move(plugin_cols));
  auto install_page = Container::Horizontal({skill_col | flex, plugin_col | flex});

  // ---- Update 页：Radiobox 全部/选中 ----
  const std::vector<std::string> update_entries = {"全部外部 skills + plugins",
                                                   "选中的项目"};
  auto update_page = Radiobox(update_entries, &state.update_mode);

  // ---- Uninstall 页：Radiobox 模式 + typed 项 Checkbox ----
  Components uninstall_checks;
  for (size_t i = 0; i < manifest.skills.size(); ++i) {
    uninstall_checks.push_back(Checkbox(
        "[skill]  " + manifest.skills[i].name + "  " +
            TruncateUtf8(manifest.skills[i].note, 26),
        &runner.uninstall_selected[i].value));
  }
  for (size_t i = 0; i < manifest.plugins.size(); ++i) {
    uninstall_checks.push_back(Checkbox(
        "[plugin] " + manifest.plugins[i].name + "  " +
            TruncateUtf8(manifest.plugins[i].note, 26),
        &runner.uninstall_selected[manifest.skills.size() + i].value));
  }
  const std::vector<std::string> uninstall_entries = {
      "完全卸载 (core + skills + plugins)", "仅 core", "选中的项目"};
  auto uninstall_page = Container::Vertical({
      Radiobox(uninstall_entries, &state.uninstall_mode) | center,
      Container::Vertical(std::move(uninstall_checks)) | flex | border,
  });

  // ---- 日志面板与顶部 tab 指示 ----
  auto log_view = MakeLogView(&runner);
  auto tab_indicator = MakeTabIndicator(&state);

  // 机器可读选择记录（tab 分隔；item 形如 skill:NAME / plugin:NAME / all / core）
  auto PrintSelection = [&](std::string action, const std::string& items) {
    dprintf(execution_fd, "%s\t%s\n", action.c_str(), items.c_str());
    fsync(execution_fd);
  };

  // ---- 确认 modal ----
  auto modal_ok = Button("执行", [&] {
    if (runner.running.load()) {
      state.confirm_text = "任务正在执行，请等待当前任务完成。";
      return;
    }
    if (state.tab_selected == 1 && state.update_mode == 1 &&
        runner.SelectedSkillCount() == 0 && runner.SelectedPluginCount() == 0) {
      state.confirm_text = "未勾选任何更新项目，请先选择 skill 或 plugin。";
      return;
    }
    if (state.tab_selected == 2 && state.uninstall_mode == 2 &&
        std::none_of(runner.uninstall_selected.begin(), runner.uninstall_selected.end(),
                     [](const BoolSlot& s) { return s.value; })) {
      state.confirm_text = "未勾选任何卸载项目，请先选择 skill 或 plugin。";
      return;
    }
    state.show_modal = false;
    // 契约：确认即打印机器可读选择记录到原始 stdout，再启动后台子进程
    std::string action;
    std::string items;
    switch (state.tab_selected) {
      case 0: {
        action = "install";
        if (runner.SelectedSkillCount() == 0 && runner.SelectedPluginCount() == 0) {
          items = "all";
        } else {
          for (size_t i = 0; i < manifest.skills.size(); ++i)
            if (runner.skills_selected[i].value)
              items += (items.empty() ? "" : "\t") + std::string("skill:") +
                       manifest.skills[i].name;
          for (size_t i = 0; i < manifest.plugins.size(); ++i)
            if (runner.plugins_selected[i].value)
              items += (items.empty() ? "" : "\t") + std::string("plugin:") +
                       manifest.plugins[i].name;
        }
        break;
      }
      case 1: {
        action = "update";
        if (state.update_mode == 0) {
          items = "all";
        } else {
          for (size_t i = 0; i < manifest.skills.size(); ++i)
            if (runner.skills_selected[i].value)
              items += (items.empty() ? "" : "\t") + std::string("skill:") +
                       manifest.skills[i].name;
          for (size_t i = 0; i < manifest.plugins.size(); ++i)
            if (runner.plugins_selected[i].value)
              items += (items.empty() ? "" : "\t") + std::string("plugin:") +
                       manifest.plugins[i].name;
        }
        break;
      }
      case 2: {
        action = "uninstall";
        if (state.uninstall_mode == 0) {
          items = "all";
        } else if (state.uninstall_mode == 1) {
          items = "core";
        } else {
          for (size_t i = 0; i < manifest.skills.size(); ++i)
            if (runner.uninstall_selected[i].value)
              items += (items.empty() ? "" : "\t") + std::string("skill:") +
                       manifest.skills[i].name;
          for (size_t i = 0; i < manifest.plugins.size(); ++i)
            if (runner.uninstall_selected[manifest.skills.size() + i].value)
              items += (items.empty() ? "" : "\t") + std::string("plugin:") +
                       manifest.plugins[i].name;
        }
        break;
      }
    }
    PrintSelection(action, items);

    // 按当前页/模式启动后台子进程
    switch (state.tab_selected) {
      case 0:
        runner.Spawn(BuildInstallArgs(manifest, runner), "安装");
        break;
      case 1:
        if (state.update_mode == 0) {
          runner.Spawn({"--update-all", "--ci"}, "更新全部");
        } else {
          std::vector<std::string> args = {"--ci"};
          for (size_t i = 0; i < manifest.skills.size(); ++i)
            if (runner.skills_selected[i].value) {
              args.push_back("--update-skill");
              args.push_back(manifest.skills[i].name);
            }
          for (size_t i = 0; i < manifest.plugins.size(); ++i)
            if (runner.plugins_selected[i].value) {
              args.push_back("--update-plugin");
              args.push_back(manifest.plugins[i].name);
            }
          runner.Spawn(std::move(args), "更新选中项");
        }
        break;
      case 2:
        if (state.uninstall_mode == 0) {
          runner.Spawn({"--uninstall", "all", "--ci"}, "完全卸载");
        } else if (state.uninstall_mode == 1) {
          runner.Spawn({"--uninstall", "core", "--ci"}, "卸载 core");
        } else {
          std::vector<std::string> args = {"--ci"};
          for (size_t i = 0; i < manifest.skills.size(); ++i)
            if (runner.uninstall_selected[i].value) {
              args.push_back("--uninstall-skill");
              args.push_back(manifest.skills[i].name);
            }
          for (size_t i = 0; i < manifest.plugins.size(); ++i)
            if (runner.uninstall_selected[manifest.skills.size() + i].value) {
              args.push_back("--uninstall-plugin");
              args.push_back(manifest.plugins[i].name);
            }
          if (args.size() > 1) runner.Spawn(std::move(args), "卸载选中项");
        }
        break;
    }
  });
  auto modal_cancel = Button("取消", [&state] { state.show_modal = false; });
  auto modal_container = Container::Horizontal({modal_ok, modal_cancel});

  // 保留 modal_container 作为 Renderer child，按钮才能接收焦点与 Enter 事件。
  auto modal_view = CatchEvent(
      Renderer(modal_container, [&state, &modal_container] {
        return window(
            text(" 确认 "),
            vbox({text(state.confirm_text), separator(),
                  modal_container->Render() | center}));
      }),
      [&state](Event e) {
        if (e == Event::Escape) {
          state.show_modal = false;
          return true;
        }
        return false;
      });

  // ---- 根组件 ----
  auto tabs = Container::Tab({install_page, update_page, uninstall_page},
                             &state.tab_selected);

  auto status = std::make_shared<std::string>(
      "[1/2/3] 切页  [a] 全选/取消  [e] 执行  [q] 退出");
  bool user_quit = false;

  // Renderer(child, render) 保留 tabs 的焦点树；不能用无 child 的 Renderer，
  // 否则 checkbox/radiobox 只会被画出来而无法接收键盘事件。
  auto root = CatchEvent(
      Renderer(tabs, [&, tab_indicator, log_view, status] {
        return vbox({
            text(" Claude Code Config Installer ") | bold | center,
            separator(),
            tab_indicator->Render(),
            separator(),
            tabs->Render() | flex,
            separator(),
            log_view->Render() | flex,
            text(*status) | dim,
        });
      }),
      [&](Event e) {
        if (e == Event::Character('q') || e == Event::Character('Q')) {
          user_quit = true;
          if (App::Active()) App::Active()->Exit();
          return true;
        }
        if (e == Event::Character('1')) { state.tab_selected = 0; return true; }
        if (e == Event::Character('2')) { state.tab_selected = 1; return true; }
        if (e == Event::Character('3')) { state.tab_selected = 2; return true; }
        if (e == Event::Character('a') || e == Event::Character('A')) {
          if (state.tab_selected == 0) {
            const bool any_unchecked =
                std::any_of(runner.skills_selected.begin(),
                            runner.skills_selected.end(),
                            [](const BoolSlot& s) { return !s.value; }) ||
                std::any_of(runner.plugins_selected.begin(),
                            runner.plugins_selected.end(),
                            [](const BoolSlot& s) { return !s.value; });
            std::fill(runner.skills_selected.begin(), runner.skills_selected.end(),
                      BoolSlot{any_unchecked});
            std::fill(runner.plugins_selected.begin(), runner.plugins_selected.end(),
                      BoolSlot{any_unchecked});
          } else if (state.tab_selected == 2) {
            const bool any_unchecked =
                std::any_of(runner.uninstall_selected.begin(),
                            runner.uninstall_selected.end(),
                            [](const BoolSlot& s) { return !s.value; });
            std::fill(runner.uninstall_selected.begin(),
                      runner.uninstall_selected.end(), BoolSlot{any_unchecked});
          }
          return true;
        }
        if (e == Event::Character('e') || e == Event::Character('E') ||
            e == Event::Return) {
          state.show_modal = true;
          switch (state.tab_selected) {
            case 0:
              state.confirm_text =
                  runner.SelectedSkillCount() == 0 && runner.SelectedPluginCount() == 0
                      ? "未勾选任何项 — 将全量安装所有 skills + plugins，确认？"
                      : "安装选中的 skills/plugins，确认？";
              break;
            case 1:
              state.confirm_text = state.update_mode == 0
                                       ? "更新全部外部 skills + plugins，确认？"
                                       : "更新选中的项目，确认？";
              break;
            case 2:
              state.confirm_text = state.uninstall_mode == 0
                                       ? "完全卸载 core + 全部 skills + plugins，确认？"
                                       : state.uninstall_mode == 1
                                             ? "仅卸载 core 配置，确认？"
                                             : "卸载选中的项目，确认？";
              break;
          }
          return true;
        }
        return false;
      });

  auto main = Modal(root, modal_view, &state.show_modal);

  App app = App::FullscreenAlternateScreen();
  app.Loop(main);
  return user_quit ? runner.CancelAndWait()
                   : runner.Wait();  // 退出前回收 worker，避免 App 析构后仍 Post
}

}  // namespace installer
