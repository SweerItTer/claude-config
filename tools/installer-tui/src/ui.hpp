#pragma once

#include <filesystem>
#include <string>

#include "engine.hpp"

namespace installer {

// 运行 TUI 主界面。execution_fd 是 stdout 的原始 dup：确认执行后在这里输出
// 机器可读选择记录（tab 分隔）。main 已把 FTXUI UI 重定向到 stderr，
// 因此此处绝不写 stdout。plan 是统一资源计划（发现/冲突/选择）。
// 返回：0 = 正常退出（含用户主动取消）；2 = 用户中止错误状态。
int RunUi(const std::filesystem::path& repo_root, const Manifest& manifest,
          const ResourcePlan& plan, int execution_fd);

}  // namespace installer
