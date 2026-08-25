#include "ui.hpp"

#include <algorithm>
#include <atomic>
#include <chrono>
#include <cstddef>
#include <cstdio>
#include <set>
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
// 冲突资源的来源选择槽（Radiobox 直接绑定）：-1=未选(未决)，0/1/2=local/remote/skip
constexpr int kConflictUnset = -1;

// 统一资源计划中的本地 skill canonical id（source=local 且 kind=skill）
std::vector<std::string> LocalSkillIds(const ResourcePlan& plan) {
  std::vector<std::string> ids;
  for (const auto& r : plan.resources)
    if (r.kind == "skill" && r.source == "local") ids.push_back(r.id);
  return ids;
}

class Runner {
 public:
  Runner(const std::filesystem::path& repo_root, const Manifest& manifest,
         const ResourcePlan& plan)
      : repo_root_(repo_root),
        manifest_(manifest),
        plan_(plan),
        skills_selected(manifest.skills.size()),
        plugins_selected(manifest.plugins.size()),
        local_skill_ids(LocalSkillIds(plan)),
        uninstall_selected(manifest.skills.size() + manifest.plugins.size() +
                           local_skill_ids.size()),
        local_selected(local_skill_ids.size()),
        conflict_choices(plan.conflicts.size(), 0),
        conflict_resolved(plan.conflicts.size(), false) {}

  // 选择状态（绑定到 Checkbox 的 bool*，由 FTXUI 读写）
  // 注意：声明顺序即成员初始化顺序。uninstall_selected 依赖 local_skill_ids，
  // 因此 local_skill_ids 必须声明在它前面。
  std::vector<BoolSlot> skills_selected;
  std::vector<BoolSlot> plugins_selected;
  // 统一资源中的本地 skill（canonical id）与勾选
  std::vector<std::string> local_skill_ids;
  std::vector<BoolSlot> local_selected;
  std::vector<BoolSlot> uninstall_selected;

  // 冲突资源逐项来源选择（与 plan.conflicts 一一对应）：0/1/2=local/remote/skip。
  // conflict_resolved[i] 标记用户是否操作过该 radiobox——FTXUI 渲染时 Clamp() 会把
  // int* 钳到 [0,size-1]，不能用哨兵值表示"未选"，故单独用 bool 标志，on_change 才置位。
  std::vector<int> conflict_choices;
  std::vector<bool> conflict_resolved;

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
  int SelectedLocalCount() const {
    return static_cast<int>(std::count_if(
        local_selected.begin(), local_selected.end(),
        [](const BoolSlot& s) { return s.value; }));
  }
  // 是否有未决冲突（用户未逐项选择来源）
  bool HasUnresolvedConflict() const {
    return std::any_of(conflict_resolved.begin(), conflict_resolved.end(),
                       [](bool r) { return !r; });
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
  const ResourcePlan& plan_;
  std::thread worker_;
};

// 为单个资源追加显式来源选择 --choose kind:id=local|remote（来源前缀确定）。
// uninstall/update 页条目带 [local]/[skill]/[plugin] 前缀，勾选即来源选择；
// 冲突资源必须带 --choose 否则 setup.sh 的 resolver 会因非交互未决冲突返回 2。
void AppendResourceChoice(const ResourcePlan& plan, const std::string& kind,
                          const std::string& id, const std::string& source,
                          std::vector<std::string>* args) {
  // 该 (kind,id) 是否在计划冲突列表里——只有冲突资源才需要 --choose。
  bool conflicted = false;
  for (const auto& c : plan.conflicts)
    if (c.kind == kind && c.id == id) conflicted = true;
  if (!conflicted) return;
  args->push_back("--choose");
  args->push_back(kind + ":" + id + "=" + source);
}

// 把已解决的冲突选择追加为 --choose kind:id=value argv（未决冲突由调用方已拦截）。
// 0/1/2 = local/remote/skip，对应 plan.conflicts 顺序。
void AppendConflictChoices(const ResourcePlan& plan, const Runner& r,
                           std::vector<std::string>* args) {
  static const char* kValues[] = {"local", "remote", "skip"};
  for (size_t i = 0; i < plan.conflicts.size(); ++i) {
    if (!r.conflict_resolved[i]) continue;  // 未决冲突由调用方已拦截，这里只加已选
    const int choice = r.conflict_choices[i];
    if (choice < 0 || choice > 2) continue;
    args->push_back("--choose");
    args->push_back(plan.conflicts[i].kind + ":" + plan.conflicts[i].id +
                    "=" + kValues[choice]);
  }
}

// 依据当前勾选构造安装 argv。
// 三类（本地 skill / 外部 skills / plugins）都未勾选 = 全量（--ci 不带 skip）；
// 未勾选其中一类 = 显式 --skip-* / 本地 skill 走 --update-local-skill 同步。
std::vector<std::string> BuildInstallArgs(const Manifest& m, const Runner& r) {
  std::vector<std::string> args = {"install", "--ci"};
  const int lk = r.SelectedLocalCount();
  const int sk = r.SelectedSkillCount();
  const int pk = r.SelectedPluginCount();
  const bool any_selected = (lk + sk + pk) > 0;
  if (!any_selected) return args;
  if (lk > 0) {
    for (size_t i = 0; i < r.local_skill_ids.size(); ++i)
      if (r.local_selected[i].value) {
        args.push_back("--update-local-skill");
        args.push_back(r.local_skill_ids[i]);
      }
  }
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
  int tab_selected = 0;     // 0=Install 1=Update 2=Uninstall 3=诊断 4=Pi Skills
  int update_mode = 0;      // 0=全部 1=选中项
  int uninstall_mode = 0;   // 0=全部 1=core 2=选中项
  int diagnose_mode = 0;    // 0=verify 1=status 2=doctor
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
    const char* names[] = {"1 Install", "2 Update", "3 Uninstall", "4 诊断", "5 Pi Skills"};
    for (int i = 0; i < 5; ++i) {
      cells.push_back(text(names[i]) | (i == state->tab_selected ? bold : dim));
      cells.push_back(text("   "));
    }
    return hbox(cells) | center;
  });
}

}  // namespace

int RunUi(const std::filesystem::path& repo_root, const Manifest& manifest,
          const ResourcePlan& plan, int execution_fd) {
  Runner runner(repo_root, manifest, plan);
  UiState state;

  // ---- Install 页：统一资源三列 —— 本地 skills / 外部 skills / plugins ----
  // 外部 skill 用 source alias 展示，本地 skill 用 canonical id。
  Components local_cols, skill_cols, plugin_cols;
  for (size_t i = 0; i < runner.local_skill_ids.size(); ++i) {
    local_cols.push_back(Checkbox("[local] " + runner.local_skill_ids[i],
                                  &runner.local_selected[i].value));
  }
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
  auto local_col = Container::Vertical(std::move(local_cols));
  auto skill_col = Container::Vertical(std::move(skill_cols));
  auto plugin_col = Container::Vertical(std::move(plugin_cols));
  // 跳过空列：空 Vertical 会渲染 "Empty container" 并占据初始焦点，吞掉按键
  Components install_cols;
  if (!runner.local_skill_ids.empty()) install_cols.push_back(local_col | flex);
  if (!manifest.skills.empty()) install_cols.push_back(skill_col | flex);
  if (!manifest.plugins.empty()) install_cols.push_back(plugin_col | flex);
  auto install_page = Container::Horizontal(std::move(install_cols));

  // ---- 冲突区块：同名 local/remote 候选逐项三选一 ----
  // 每个冲突显示候选来源（本地路径 vs 远程 URL/repository），radiobox 选 local/remote/skip。
  const std::vector<std::string> conflict_choices_labels = {"local", "remote", "skip"};
  Components conflict_boxes;
  for (size_t i = 0; i < plan.conflicts.size(); ++i) {
    const auto& c = plan.conflicts[i];
    std::string local_path, remote_repo;
    for (const auto& r : plan.resources) {
      if (r.kind == c.kind && r.id == c.id) {
        if (r.source == "local" && !r.path.empty()) local_path = r.path;
        if (r.source == "remote" && !r.repo.empty()) remote_repo = r.repo;
      }
    }
    const std::string label =
        "[冲突] " + c.kind + ":" + c.id + "  local=" +
        TruncateUtf8(local_path.empty() ? "无" : local_path, 24) +
        "  remote=" + TruncateUtf8(remote_repo.empty() ? "无" : remote_repo, 24);
    RadioboxOption opt;
    opt.entries = conflict_choices_labels;
    opt.selected = &runner.conflict_choices[i];
    opt.on_change = [&runner, i] { runner.conflict_resolved[i] = true; };
    // radiobox 作为 Horizontal 第一个子组件（selector=0 指向它），label 仅显示。
    // 不能把 label 做成独立 Renderer 放 radiobox 之前——Vertical 的 active child
    // 会落到 label 上，Renderer 不处理空格，冲突选择永远收不到按键。
    conflict_boxes.push_back(Container::Horizontal(
        {Radiobox(opt), Renderer([label] { return text(label) | dim; })}));
  }
  auto conflict_block = Container::Vertical(std::move(conflict_boxes));
  // 有冲突时把冲突区块叠在资源列表上方，未决冲突不得执行。
  // 冲突 radiobox 初始聚焦：焦点默认在 install 页 checkbox，空格会勾选资源而非选来源。
  Component install_page_full = install_page;
  if (!plan.conflicts.empty()) {
    // conflict_block 必须是第一个子组件：Vertical 的 selector 默认=0，事件才能到达 radiobox。
    // 提示文字用 Renderer 放在 radiobox 之后（Renderer 无焦点，不影响事件分发）。
    install_page_full = Container::Vertical(
        {conflict_block, install_page | flex,
         Renderer([&] { return text("⚠ 冲突资源须选择来源") | bold; })});
  }

  // ---- Update 页：Radiobox 全部/选中 ----
  const std::vector<std::string> update_entries = {"全部外部 skills + plugins",
                                                   "选中的项目"};
  auto update_page = Radiobox(update_entries, &state.update_mode);

  // ---- Uninstall 页：Radiobox 模式 + typed 项 Checkbox（含本地 skill）----
  // 本地 skill 排在外部 skills 之后；uninstall_selected 布局：
  //   [0, manifest.skills.size())  外部 skills
  //   [.., +manifest.plugins.size()) plugins
  //   [.., +local_skill_ids.size()) 本地 skills
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
  for (size_t i = 0; i < runner.local_skill_ids.size(); ++i) {
    uninstall_checks.push_back(Checkbox(
        "[local]  " + runner.local_skill_ids[i],
        &runner.uninstall_selected[manifest.skills.size() + manifest.plugins.size() +
                                   i].value));
  }
  const std::vector<std::string> uninstall_entries = {
      "完全卸载 (core + skills + plugins)", "仅 core", "选中的项目"};
  auto uninstall_page = Container::Vertical({
      Radiobox(uninstall_entries, &state.uninstall_mode) | center,
      Container::Vertical(std::move(uninstall_checks)) | flex | border,
  });

  // ---- 诊断页：暴露 CLI 的 verify/status/doctor（三者共享同一 inspection flow）----
  // 只读检查，不修改资源；执行 setup.sh <action> --ci。
  const std::vector<std::string> diagnose_entries = {"verify", "status", "doctor"};
  const char* diagnose_actions[] = {"verify", "status", "doctor"};
  auto diagnose_page = Container::Vertical({
      Radiobox(diagnose_entries, &state.diagnose_mode) | center,
      Renderer([&] {
        return text(" 只读检查：核心配置状态 + 生命周期模块状态（与 CLI verify/status/doctor 相同）") |
               dim;
      }),
  });

  // ---- Pi Skills 页：只安装 skills 到 ~/.pi/agent/skills/（pi 只支持 skills）----
  // 复用外部 skills + 本地 skills 的勾选状态（与 Install 页同源，pi 不涉及 plugins）。
  // 未勾选 = 全量；勾选 = 指定安装（外部 --skill / 本地 --update-local-skill）。
  Components pi_local_cols, pi_skill_cols;
  for (size_t i = 0; i < runner.local_skill_ids.size(); ++i) {
    pi_local_cols.push_back(Checkbox("[local] " + runner.local_skill_ids[i],
                                     &runner.local_selected[i].value));
  }
  for (size_t i = 0; i < manifest.skills.size(); ++i) {
    pi_skill_cols.push_back(Checkbox(manifest.skills[i].name + "  " +
                                         TruncateUtf8(manifest.skills[i].note, 36),
                                     &runner.skills_selected[i].value));
  }
  auto pi_local_col = Container::Vertical(std::move(pi_local_cols));
  auto pi_skill_col = Container::Vertical(std::move(pi_skill_cols));
  Components pi_cols;
  if (!runner.local_skill_ids.empty()) pi_cols.push_back(pi_local_col | flex);
  if (!manifest.skills.empty()) pi_cols.push_back(pi_skill_col | flex);
  if (pi_cols.empty()) {
    // 空页：无 skills 可选时给占位，避免 Empty container 吞焦点
    pi_cols.push_back(Renderer([] { return text("（无 skills 可安装）") | dim; }));
  }
  auto pi_page = Container::Vertical({
      Container::Horizontal(std::move(pi_cols)) | flex,
      Renderer([&] {
        return text(" 只安装 skills → ~/.pi/agent/skills/（外部 npx -a pi + 仓库自有 symlink；"
                    "不装 claude 配置/plugins）") | dim;
      }),
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
    // 只有 install 页依赖冲突块做来源选择：install 追加的是 BuildInstallArgs 里
    // 显式的 --update-local-skill / --skill / --skip，冲突资源必须先在冲突块选来源。
    // update/uninstall 页条目带来源前缀，勾选即来源选择，不经过冲突块。
    if (state.tab_selected == 0 && runner.HasUnresolvedConflict()) {
      state.confirm_text = "存在未解决的资源冲突，请先逐项选择 local/remote/skip。";
      return;
    }
    // uninstall 页跨来源同选预检：本地+远程同名条目同时勾选 = 用户无法决定来源，
    // 必须在关闭 modal 前报错，否则 confirm_text 无处显示且 argv 会含矛盾 --choose。
    if (state.tab_selected == 2 && state.uninstall_mode == 2) {
      std::set<std::string> conflicted_ids;  // 冲突资源里被勾选的 "kind:id"
      std::set<std::string> multi_source;    // 同时勾了本地+远程的来源矛盾项
      for (size_t i = 0; i < runner.local_skill_ids.size(); ++i)
        if (runner.uninstall_selected[manifest.skills.size() + manifest.plugins.size() +
                                     i].value)
          conflicted_ids.insert("skill:" + runner.local_skill_ids[i]);
      for (size_t i = 0; i < manifest.skills.size(); ++i)
        if (runner.uninstall_selected[i].value) {
          const std::string key = "skill:" + manifest.skills[i].name;
          if (conflicted_ids.count(key)) multi_source.insert(key);
        }
      if (!multi_source.empty()) {
        std::string names;
        for (const auto& k : multi_source) names += (names.empty() ? "" : " ") + k;
        state.confirm_text =
            "冲突资源 " + names +
            " 同时勾选了本地与远程条目，来源冲突。请只勾选一个来源。";
        return;
      }
    }
    if (state.tab_selected == 1 && state.update_mode == 1 &&
        runner.SelectedSkillCount() == 0 && runner.SelectedPluginCount() == 0 &&
        runner.SelectedLocalCount() == 0) {
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
        if (runner.SelectedSkillCount() == 0 && runner.SelectedPluginCount() == 0 &&
            runner.SelectedLocalCount() == 0) {
          items = "all";
        } else {
          for (size_t i = 0; i < runner.local_skill_ids.size(); ++i)
            if (runner.local_selected[i].value)
              items += (items.empty() ? "" : "\t") + std::string("skill:") +
                       runner.local_skill_ids[i];
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
          for (size_t i = 0; i < runner.local_skill_ids.size(); ++i)
            if (runner.local_selected[i].value)
              items += (items.empty() ? "" : "\t") + std::string("skill:") +
                       runner.local_skill_ids[i];
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
          for (size_t i = 0; i < runner.local_skill_ids.size(); ++i)
            if (runner.uninstall_selected[manifest.skills.size() + manifest.plugins.size() +
                                         i].value)
              items += (items.empty() ? "" : "\t") + std::string("skill:") +
                       runner.local_skill_ids[i];
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
      case 3: {
        action = diagnose_actions[state.diagnose_mode];
        items = "all";  // 诊断是只读整体检查，无逐项选择
        break;
      }
      case 4: {
        action = "pi-install";
        if (runner.SelectedSkillCount() == 0 && runner.SelectedLocalCount() == 0) {
          items = "all";
        } else {
          for (size_t i = 0; i < runner.local_skill_ids.size(); ++i)
            if (runner.local_selected[i].value)
              items += (items.empty() ? "" : "\t") + std::string("skill:") +
                       runner.local_skill_ids[i];
          for (size_t i = 0; i < manifest.skills.size(); ++i)
            if (runner.skills_selected[i].value)
              items += (items.empty() ? "" : "\t") + std::string("skill:") +
                       manifest.skills[i].name;
        }
        break;
      }
    }
    PrintSelection(action, items);

    // 按当前页/模式启动后台子进程
    switch (state.tab_selected) {
      case 0: {
        std::vector<std::string> args = BuildInstallArgs(manifest, runner);
        AppendConflictChoices(plan, runner, &args);
        runner.Spawn(std::move(args), "安装");
        break;
      }
      case 1:
        if (state.update_mode == 0) {
          // 全部资源：统一 resolver 入口，逐资源 --update-resource（含本地 skill 与冲突选择）
          std::vector<std::string> args = {"--ci"};
          for (size_t i = 0; i < runner.local_skill_ids.size(); ++i) {
            args.push_back("--update-resource");
            args.push_back("skill:" + runner.local_skill_ids[i]);
          }
          for (const auto& s : manifest.skills) {
            args.push_back("--update-resource");
            args.push_back("skill:" + s.name);
          }
          for (const auto& p : manifest.plugins) {
            args.push_back("--update-resource");
            args.push_back("plugin:" + p.name);
          }
          AppendConflictChoices(plan, runner, &args);
          runner.Spawn(std::move(args), "更新全部");
        } else {
          std::vector<std::string> args = {"--ci"};
          // 本地 skill → --update-local-skill（走 symlink 同步）
          for (size_t i = 0; i < runner.local_skill_ids.size(); ++i)
            if (runner.local_selected[i].value) {
              args.push_back("--update-local-skill");
              args.push_back(runner.local_skill_ids[i]);
            }
          for (size_t i = 0; i < manifest.skills.size(); ++i)
            if (runner.skills_selected[i].value) {
              args.push_back("--update-resource");
              args.push_back(std::string("skill:") + manifest.skills[i].name);
            }
          for (size_t i = 0; i < manifest.plugins.size(); ++i)
            if (runner.plugins_selected[i].value) {
              args.push_back("--update-resource");
              args.push_back(std::string("plugin:") + manifest.plugins[i].name);
            }
          AppendConflictChoices(plan, runner, &args);
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
          // 冲突资源来源选择：同一 (kind,id) 只能选一次，本地优先。
          // 本地 + 远程同名条目都被勾选 = 用户无法决定，报错，不静默覆盖。
          std::set<std::string> choose_done;   // 已追加 --choose 的 "kind:id"
          std::set<std::string> choose_warn;   // 出现跨来源矛盾选择的 "kind:id"
          auto add_choice = [&](const std::string& kind, const std::string& id,
                                const std::string& source) {
            // 仅冲突资源需要 --choose
            bool conflicted = false;
            for (const auto& c : plan.conflicts)
              if (c.kind == kind && c.id == id) conflicted = true;
            if (!conflicted) return;
            const std::string key = kind + ":" + id;
            if (choose_done.count(key)) {
              choose_warn.insert(key);
              return;
            }
            choose_done.insert(key);
            args.push_back("--choose");
            args.push_back(key + "=" + source);
          };
          // 本地 skill → --uninstall-resource（走统一 resolver，只删 symlink）
          for (size_t i = 0; i < runner.local_skill_ids.size(); ++i)
            if (runner.uninstall_selected[manifest.skills.size() + manifest.plugins.size() +
                                         i].value) {
              args.push_back("--uninstall-resource");
              args.push_back("skill:" + runner.local_skill_ids[i]);
              add_choice("skill", runner.local_skill_ids[i], "local");
            }
          for (size_t i = 0; i < manifest.skills.size(); ++i)
            if (runner.uninstall_selected[i].value) {
              args.push_back("--uninstall-resource");
              args.push_back(std::string("skill:") + manifest.skills[i].name);
              add_choice("skill", manifest.skills[i].name, "remote");
            }
          for (size_t i = 0; i < manifest.plugins.size(); ++i)
            if (runner.uninstall_selected[manifest.skills.size() + i].value) {
              args.push_back("--uninstall-resource");
              args.push_back(std::string("plugin:") + manifest.plugins[i].name);
              add_choice("plugin", manifest.plugins[i].name, "remote");
            }
          if (!choose_warn.empty()) {
            std::string names;
            for (const auto& k : choose_warn) names += (names.empty() ? "" : " ") + k;
            state.confirm_text =
                "冲突资源 " + names +
                " 同时勾选了本地与远程条目，来源冲突。请只勾选一个来源。";
            return;
          }
          if (args.size() > 1) runner.Spawn(std::move(args), "卸载选中项");
        }
        break;
      case 3: {
        // 诊断：只读整体检查，setup.sh <action> --ci
        std::vector<std::string> args = {diagnose_actions[state.diagnose_mode], "--ci"};
        runner.Spawn(std::move(args), std::string("诊断: ") + diagnose_actions[state.diagnose_mode]);
        break;
      }
      case 4: {
        // Pi Skills：只装 skills 到 ~/.pi/agent/skills/（pi 只支持 skills）
        std::vector<std::string> args = {"install", "--agents=pi", "--ci"};
        if (runner.SelectedSkillCount() > 0 || runner.SelectedLocalCount() > 0) {
          for (size_t i = 0; i < runner.local_skill_ids.size(); ++i)
            if (runner.local_selected[i].value) {
              args.push_back("--update-local-skill");
              args.push_back(runner.local_skill_ids[i]);
            }
          for (size_t i = 0; i < manifest.skills.size(); ++i)
            if (runner.skills_selected[i].value) {
              args.push_back("--skill");
              args.push_back(manifest.skills[i].name);
            }
        }
        runner.Spawn(std::move(args), "安装 Pi skills");
        break;
      }
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
  auto tabs = Container::Tab(
      {install_page_full, update_page, uninstall_page, diagnose_page, pi_page},
      &state.tab_selected);

  auto status = std::make_shared<std::string>(
      "[1/2/3/4/5] 切页  [a] 全选/取消  [e] 执行  [q] 退出");
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
        if (e == Event::Character('1')) {
          state.tab_selected = 0;
          // Tab 切换不自动转移焦点；显式把焦点移到目标页，
          // 否则切页后按键仍被原页焦点（如冲突 radiobox）吞掉。
          install_page_full->TakeFocus();
          return true;
        }
        if (e == Event::Character('2')) {
          state.tab_selected = 1;
          update_page->TakeFocus();
          return true;
        }
        if (e == Event::Character('3')) {
          state.tab_selected = 2;
          uninstall_page->TakeFocus();
          return true;
        }
        if (e == Event::Character('4')) {
          state.tab_selected = 3;
          diagnose_page->TakeFocus();
          return true;
        }
        if (e == Event::Character('5')) {
          state.tab_selected = 4;
          pi_page->TakeFocus();
          return true;
        }
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
          } else if (state.tab_selected == 4) {
            // Pi 页：只全选外部 + 本地 skills，不涉及 plugins
            const bool any_unchecked =
                std::any_of(runner.skills_selected.begin(),
                            runner.skills_selected.end(),
                            [](const BoolSlot& s) { return !s.value; }) ||
                std::any_of(runner.local_selected.begin(),
                            runner.local_selected.end(),
                            [](const BoolSlot& s) { return !s.value; });
            std::fill(runner.skills_selected.begin(), runner.skills_selected.end(),
                      BoolSlot{any_unchecked});
            std::fill(runner.local_selected.begin(), runner.local_selected.end(),
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
          // modal 已打开时放行事件：焦点在确认/取消按钮，回车/空格必须能触发
          if (state.show_modal) return false;
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
            case 3:
              state.confirm_text =
                  std::string("运行 ") + diagnose_actions[state.diagnose_mode] +
                  "（只读检查），确认？";
              break;
            case 4:
              state.confirm_text =
                  runner.SelectedSkillCount() == 0 && runner.SelectedLocalCount() == 0
                      ? "未勾选任何项 — 将全量安装所有 skills 到 ~/.pi/agent/skills/，确认？"
                      : "安装选中的 skills 到 ~/.pi/agent/skills/（pi 只支持 skills，不装 claude 配置/plugins），确认？";
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
