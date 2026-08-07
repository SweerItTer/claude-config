#ifndef _GNU_SOURCE
#define _GNU_SOURCE
#endif
#include "engine.hpp"

#include <cerrno>
#include <fcntl.h>
#include <poll.h>
#include <signal.h>
#include <sys/wait.h>
#include <unistd.h>

#include <atomic>
#include <chrono>
#include <cstdlib>
#include <cstring>
#include <iostream>
#include <sstream>
#include <stdexcept>
#include <thread>

namespace installer {
namespace {

// 字段含 tab/换行/回车会破坏 TSV 协议，直接判定非法
bool HasControlChar(const std::string& s) {
  return s.find('\t') != std::string::npos || s.find('\n') != std::string::npos ||
         s.find('\r') != std::string::npos;
}

// 按 tab 切 6 列；列数不足视为坏行
bool SplitTsv(const std::string& line, std::vector<std::string>* cols) {
  cols->clear();
  std::string cur;
  for (char c : line) {
    if (c == '\t') {
      cols->push_back(cur);
      cur.clear();
    } else {
      cur.push_back(c);
    }
  }
  cols->push_back(cur);
  return cols->size() == 6;
}

// 运行一个子进程，stdout/stderr 合并到同一管道，逐行回调 on_output，返回退出码。
// 不经 /bin/sh -c：argv 直接 execvp，杜绝字符串拼接注入。
int RunProcess(const std::vector<std::string>& argv,
               const std::filesystem::path& cwd, const OutputCallback& on_output,
               std::string* error,
               const std::atomic<bool>* cancel_requested = nullptr) {
  int pipefd[2];
#if defined(O_CLOEXEC)
  if (pipe2(pipefd, O_CLOEXEC) != 0) {
    if (error) *error = "pipe2() failed";
    return -1;
  }
#else
  if (pipe(pipefd) != 0) {
    if (error) *error = "pipe() failed";
    return -1;
  }
  for (int fd : pipefd) {
    if (fcntl(fd, F_SETFD, FD_CLOEXEC) != 0) {
      if (error) *error = "fcntl(FD_CLOEXEC) failed";
      close(pipefd[0]);
      close(pipefd[1]);
      return -1;
    }
  }
#endif

  pid_t pid = fork();
  if (pid < 0) {
    if (error) *error = "fork() failed";
    close(pipefd[0]);
    close(pipefd[1]);
    return -1;
  }

  if (pid == 0) {
    // 子进程组仅由本次 fork 创建，取消时可安全定向终止。
    if (setpgid(0, 0) != 0) _exit(127);
    // 子进程：stdout/stderr → 管道写端
    dup2(pipefd[1], STDOUT_FILENO);
    dup2(pipefd[1], STDERR_FILENO);
    close(pipefd[0]);
    close(pipefd[1]);

    if (!cwd.empty()) {
      if (chdir(cwd.c_str()) != 0) {
        _exit(127);
      }
    }

    std::vector<char*> cargv;
    cargv.reserve(argv.size() + 1);
    for (const auto& a : argv) cargv.push_back(const_cast<char*>(a.c_str()));
    cargv.push_back(nullptr);
    execvp(cargv[0], cargv.data());
    _exit(127);  // exec 失败
  }

  // 父进程也设置 pgid，覆盖 child 尚未运行到 setpgid 的短窗口。
  if (setpgid(pid, pid) != 0 && errno != ESRCH && errno != EACCES) {
    if (error) *error = "setpgid() failed";
    close(pipefd[0]);
    close(pipefd[1]);
    kill(pid, SIGKILL);
    waitpid(pid, nullptr, 0);
    return -1;
  }

  // 父进程：轮询管道和子进程，取消时只终止本次子进程组。
  close(pipefd[1]);
  std::string partial;
  char chunk[4096];
  bool read_failed = false;
  bool cancelled = false;
  bool child_reaped = false;
  int status = 0;
  for (;;) {
    if (!child_reaped && cancel_requested && cancel_requested->load()) {
      cancelled = true;
      if (kill(-pid, SIGTERM) != 0 && errno != ESRCH) {
        if (error) *error = "kill(SIGTERM) failed";
      }
      std::this_thread::sleep_for(std::chrono::milliseconds(20));
      if (kill(-pid, SIGKILL) != 0 && errno != ESRCH) {
        if (error) *error = "kill(SIGKILL) failed";
      }
    }

    struct pollfd pfd = {pipefd[0], POLLIN, 0};
    const int poll_rc = poll(&pfd, 1, child_reaped ? 0 : 50);
    if (poll_rc < 0) {
      if (errno == EINTR) continue;
      if (error) *error = "poll() failed";
      read_failed = true;
    } else if (poll_rc > 0 && (pfd.revents & (POLLIN | POLLHUP))) {
      const ssize_t n = read(pipefd[0], chunk, sizeof(chunk));
      if (n > 0) {
        partial.append(chunk, static_cast<size_t>(n));
        size_t newline;
        while ((newline = partial.find('\n')) != std::string::npos) {
          if (on_output) on_output(partial.substr(0, newline));
          partial.erase(0, newline + 1);
        }
      } else if (n == 0) {
        close(pipefd[0]);
        pipefd[0] = -1;
      } else if (errno != EINTR) {
        if (error) *error = "read() failed";
        read_failed = true;
      }
    }

    if (!child_reaped) {
      const pid_t waited = waitpid(pid, &status, WNOHANG);
      if (waited == pid) child_reaped = true;
      else if (waited < 0 && errno != EINTR) {
        if (error) *error = "waitpid() failed";
        break;
      }
    }
    if (child_reaped && pipefd[0] < 0) break;
  }
  if (pipefd[0] >= 0) close(pipefd[0]);
  if (!partial.empty() && on_output) on_output(partial);
  if (read_failed || !child_reaped) return -1;
  if (cancelled) return 0;
  if (WIFEXITED(status)) return WEXITSTATUS(status);
  return 1;
}

}  // namespace

bool LoadManifests(const std::filesystem::path& repo_root, Manifest* out,
                   std::string* error) {
  auto load_kind = [&](const char* kind,
                       const char* manifest_name,
                       auto* dest) -> bool {
    const auto parser = repo_root / "script" / "parse-manifests.py";
    const auto file = repo_root / "configs" / manifest_name;
    if (!std::filesystem::exists(file)) {
      if (error) *error = "missing manifest: configs/" + std::string(manifest_name);
      return false;
    }
    std::vector<std::string> argv = {"python3", parser.string(),
                                     kind,       "--file",
                                     file.string()};
    CollectedOutput co;
    std::string perr;
    int rc = RunProcess(argv, repo_root,
                        [&co](const std::string& l) { co.OnLine(l); }, &perr);
    if (rc != 0) {
      if (error) *error = "parse-manifests.py " + std::string(kind) + " exited " +
                          std::to_string(rc) + ": " + perr;
      return false;
    }

    std::istringstream iss(co.text);
    std::string line;
    while (std::getline(iss, line)) {
      if (line.empty()) continue;  // 合法空清单
      std::vector<std::string> cols;
      if (!SplitTsv(line, &cols)) {
        if (error) *error = "bad " + std::string(kind) +
                            " TSV row (need 6 columns): " + line;
        return false;
      }
      // skills: name repo skill agent scope note
      // plugins: name repo method marketplace command note
      typename std::remove_reference<decltype(*dest)>::type::value_type item;
      item.name = cols[0];
      item.repo = cols[1];
      if (item.name.empty() || item.repo.empty()) {
        if (error) *error = "empty name/repo in " + std::string(kind) +
                            " manifest row: " + line;
        return false;
      }
      if (HasControlChar(item.name) || HasControlChar(item.repo)) {
        if (error) *error = "control char in name/repo of " + std::string(kind);
        return false;
      }
      // 其余字段按类别赋值
      if constexpr (std::is_same_v<typename std::remove_reference<decltype(*dest)>::type::value_type,
                                   SkillEntry>) {
        item.skill = cols[2];
        item.agent = cols[3];
        item.scope = cols[4];
        item.note = cols[5];
      } else {
        item.method = cols[2];
        item.marketplace = cols[3];
        item.command = cols[4];
        item.note = cols[5];
      }
      // 同类内重名 fatal（跨类重名允许，卸载用 typed 区分）
      for (const auto& existing : *dest) {
        if (existing.name == item.name) {
          if (error) *error = "duplicate " + std::string(kind) +
                              " name in manifest: " + item.name;
          return false;
        }
      }
      dest->push_back(item);
    }
    return true;
  };

  out->skills.clear();
  out->plugins.clear();
  if (!load_kind("skills", "skills.toml", &out->skills)) return false;
  if (!load_kind("plugins", "plugins.toml", &out->plugins)) return false;
  return true;
}

int RunSetup(const std::filesystem::path& repo_root,
             const std::vector<std::string>& args,
             const OutputCallback& on_output,
             const std::atomic<bool>* cancel_requested) {
  std::vector<std::string> argv;
  argv.reserve(args.size() + 2);
  argv.push_back("bash");
  argv.push_back((repo_root / "setup.sh").string());
  for (const auto& a : args) argv.push_back(a);
  std::string error;
  int rc = RunProcess(argv, repo_root, on_output, &error, cancel_requested);
  if (rc < 0) {
    if (on_output) on_output("[ERR] 无法启动 setup.sh: " + error);
    return 1;
  }
  return rc;
}

}  // namespace installer
