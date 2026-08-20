#pragma once

#include <atomic>
#include <filesystem>
#include <functional>
#include <string>
#include <vector>

namespace installer {

// 清单项：skills.toml / plugins.toml 经 parse-manifests.py 输出的 6 列 TSV
struct SkillEntry {
  std::string name;
  std::string repo;
  std::string skill;
  std::string agent;
  std::string scope;
  std::string note;
};

struct PluginEntry {
  std::string name;
  std::string repo;
  std::string method;
  std::string marketplace;
  std::string command;
  std::string note;
};

struct Manifest {
  std::vector<SkillEntry> skills;
  std::vector<PluginEntry> plugins;
};

struct ResourceEntry {
  std::string kind;
  std::string id;
  std::string source;
  std::string name;
  std::string repo;
  std::string marketplace;
  std::string path;
};

struct ResourceChoice {
  std::string kind;
  std::string id;
  std::string action;
};

struct ResourceConflict {
  std::string kind;
  std::string id;
};

struct ResourcePlan {
  std::vector<ResourceEntry> resources;
  std::vector<ResourceChoice> plan;
  std::vector<ResourceConflict> conflicts;
};

// 加载统一资源计划（resource-plan.py --format tsv 的 9 列 TSV）。
// 每个候选资源一行；conflict=1 表示该 (kind,id) 有未决冲突（action 为空），
// TUI 必须让用户逐项选择 local/remote/skip。冲突存在时该函数仍成功返回
// （conflicts 非空），由 UI 决定如何呈现；协议破坏（列数不足/非 6 列）才失败。
bool LoadResourcePlan(const std::filesystem::path& repo_root, ResourcePlan* out,
                      std::string* error);

// 在 stdout 上原样透传 resource-plan.py --format tsv 的机器可读记录
// （--print-selection 用）。返回计划层退出码（0=无冲突，2=有未决冲突），
// 启动失败返回 -1 并填 error。
int PrintResourcePlan(const std::filesystem::path& repo_root, std::string* error);

// 执行 setup.sh 子进程时的输出回调（逐行）
using OutputCallback = std::function<void(const std::string&)>;

// 解析清单：调用 script/parse-manifests.py skills|plugins --file <path>，读 6 列 TSV。
// 失败（parser 非零/文件缺失/坏列/空名/同类重名/字段含控制字符）时返回 false 并填 error。
bool LoadManifests(const std::filesystem::path& repo_root, Manifest* out,
                   std::string* error);

// 在 repo_root 下运行 setup.sh，实时把 stdout/stderr 逐行回调 on_output。
// 返回 setup.sh 的退出码。
int RunSetup(const std::filesystem::path& repo_root,
             const std::vector<std::string>& args,
             const OutputCallback& on_output,
             const std::atomic<bool>* cancel_requested = nullptr);

// 便捷回调：把全部输出拼接为单个字符串（用于同步调用、测试）
struct CollectedOutput {
  std::string text;
  void OnLine(const std::string& line) { text += line + "\n"; }
};

}  // namespace installer
