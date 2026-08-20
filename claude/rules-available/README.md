# Rules Index — 按需加载规则目录

此目录下的规则**不会**被 Claude Code 自动加载。编辑代码时按需读取对应规则集。

## 快速查找

| 编辑文件类型 | 加载规则集 |
|-------------|-----------|
| `.pl` `.perl` | `perl/` |
| `.py` | `python/` |

## 可用规则集

### 自维护 (curated)
| 目录 | 覆盖领域 |
|------|---------|
| `perl/` | coding-style, hooks, patterns, security, testing |
| `python/` | coding-style, hooks, patterns, security, testing |
| `zh/` | agents, code-review, coding-style, development-workflow, git-workflow, hooks, patterns, performance, security, testing |

## 使用协议

编辑代码前，查上表确定规则集，`Read` 对应目录。`rules/common/` 为基线始终自动加载。
