# Rules Index — 按需加载规则目录

此目录下的规则**不会**被 Claude Code 自动加载。编辑代码时按需读取对应规则集。

## 快速查找

| 编辑文件类型 | 加载规则集 |
|-------------|-----------|
| `.java` | `java/` |
| `.cpp` `.c` `.h` `.hpp` | `ecc/cpp/` `ecc/c/` |
| `.vue` `.html` | `web/` |
| `.js` `.jsx` | `typescript/` + `web/` |

## 可用规则集

### 自维护 (curated)
| 目录 | 覆盖领域 |
|------|---------|
| `java/` | coding-style, hooks, patterns, security, testing |
| `typescript/` | coding-style, hooks, patterns, security, testing |
| `web/` | coding-style, design-quality, hooks, patterns, performance, security, testing |

### ECC 官方规则 (来自 everything-claude-code)
| 目录 | 覆盖领域 |
|------|---------|
| `ecc/c/` `ecc/cpp/` | C/C++ 语言规则 |
| `ecc/java/` | Java 补充规则 |
| `ecc/javascript/` `ecc/typescript/` | JS/TS 补充规则 |
| `ecc/web/` | Web 补充规则 |

## 使用协议

编辑代码前，查上表确定规则集，`Read` 对应目录。`rules/common/` 为基线始终自动加载。
