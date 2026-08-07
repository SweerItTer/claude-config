#include <cstdio>
#include <cstdlib>
#include <cstring>
#include <filesystem>
#include <string>
#include <vector>

#include <sys/stat.h>
#include <unistd.h>

#include "engine.hpp"
#include "ui.hpp"

namespace {

namespace fs = std::filesystem;

// 平台运行时守卫：仅 Linux x86_64（CMake 配置期已检查，运行时再确认一次）
bool PlatformOk() {
#if defined(__linux__)
  return true;
#else
  return false;
#endif
}

// 从 dir 向上逐级找包含 setup.sh + configs + script 的仓库根；找不到返回空
fs::path FindRepoRoot(const fs::path& dir) {
  fs::path cur = fs::absolute(dir);
  for (;;) {
    if (fs::exists(cur / "setup.sh") && fs::is_directory(cur / "configs") &&
        fs::is_directory(cur / "script")) {
      return cur;
    }
    fs::path parent = cur.parent_path();
    if (parent == cur) break;
    cur = parent;
  }
  return {};
}

void PrintHelp(const char* prog) {
  std::fprintf(stderr,
               "Claude Config Installer TUI\n"
               "\n"
               "用法:\n"
               "  %s [选项]\n"
               "\n"
               "交互式 TUI：勾选 skills/plugins 安装、更新、卸载。\n"
               "UI 输出到 stderr；确认执行后向 stdout 打印一行机器可读选择记录\n"
               "(tab 分隔: action<TAB>items，item 形如 skill:NAME / plugin:NAME / all / core)。\n"
               "\n"
               "选项:\n"
               "  --repo-root PATH   指定仓库根（默认从当前目录向上找）\n"
               "  --print-selection  纯打印模式：打印选择记录后退出，不启动 UI\n"
               "  --help             显示本帮助\n"
               "\n"
               "仅支持 Linux x86_64。无 TTY（管道/非交互）时退出码 2。\n",
               prog);
}

}  // namespace

int main(int argc, char** argv) {
  bool print_selection = false;
  fs::path repo_root;
  for (int i = 1; i < argc; ++i) {
    const char* arg = argv[i];
    if (std::strcmp(arg, "--help") == 0 || std::strcmp(arg, "-h") == 0) {
      PrintHelp(argv[0]);
      return 0;
    }
    if (std::strcmp(arg, "--print-selection") == 0 || std::strcmp(arg, "--ci") == 0) {
      print_selection = print_selection || std::strcmp(arg, "--print-selection") == 0;
      continue;
    }
    if (std::strcmp(arg, "--repo-root") == 0) {
      if (++i >= argc || argv[i][0] == '\0' || argv[i][0] == '-') {
        std::fprintf(stderr, "installer-tui: --repo-root 需要 PATH\n");
        return 2;
      }
      repo_root = argv[i];
      continue;
    }
    std::fprintf(stderr, "installer-tui: 未知参数: %s\n", arg);
    return 2;
  }

  if (!PlatformOk()) {
    std::fprintf(stderr, "installer-tui: 仅支持 Linux x86_64\n");
    return 2;
  }

  // 无 TTY：非 --print-selection 一律退出 2（先检查 stdin 与 TERM）
  if (!isatty(STDIN_FILENO)) {
    if (!print_selection) {
      std::fprintf(stderr,
                   "installer-tui: 需要交互终端（stdin 不是 TTY）。"
                   "非交互使用请走 setup.sh CLI 或 --print-selection。\n");
      return 2;
    }
  } else {
    const char* term = std::getenv("TERM");
    if (term == nullptr || std::strcmp(term, "dumb") == 0) {
      if (!print_selection) {
        std::fprintf(stderr,
                     "installer-tui: TERM=dumb，无法渲染 TUI。"
                     "请使用 --print-selection 或交互终端。\n");
        return 2;
      }
    }
  }

  // 定位仓库根
  if (repo_root.empty()) repo_root = FindRepoRoot(fs::current_path());
  if (repo_root.empty()) {
    std::fprintf(stderr,
                 "installer-tui: 找不到仓库根（需要 setup.sh + configs/ + script/）。"
                 "请用 --repo-root 指定。\n");
    return 2;
  }

  // 解析清单（skills + plugins）
  installer::Manifest manifest;
  {
    std::string err;
    if (!installer::LoadManifests(repo_root, &manifest, &err)) {
      std::fprintf(stderr, "installer-tui: 解析清单失败: %s\n", err.c_str());
      return 2;
    }
  }

  // --print-selection：纯打印模式（无 UI），用于脚本/测试。无勾选 = all。
  if (print_selection) {
    std::string record = "all";
    std::fprintf(stdout, "install\t%s\n", record.c_str());
    return 0;
  }

  // stdout/stderr 契约：UI 全落 stderr；机器可读选择记录写原始 stdout dup。
  // selection_fd 保存原始 stdout；随后 dup2(stderr→stdout) 让 FTXUI 用 stderr 渲染。
  int selection_fd = dup(STDOUT_FILENO);
  if (selection_fd < 0) {
    std::fprintf(stderr, "installer-tui: dup(STDOUT) 失败\n");
    return 2;
  }
  if (dup2(STDERR_FILENO, STDOUT_FILENO) < 0) {
    std::fprintf(stderr, "installer-tui: dup2(STDERR->STDOUT) 失败\n");
    close(selection_fd);
    return 2;
  }

  int rc = installer::RunUi(repo_root, manifest, selection_fd);
  close(selection_fd);
  return rc;
}
