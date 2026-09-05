# mem

命令行记忆库（C3 实现，复刻 `headlong/bin/mem`）。每条记忆是一个带 YAML frontmatter 的
markdown 文件，落在一个普通目录里；`search` 子命令调用外部 `llm` 命令做语义检索。

版本 `0.1.0`（`mem --version`）。

---

## 构建

```bash
c3c build mem
./build-all.sh      # 构建 project.json 里所有 target
```

---

## 用法

```bash
mem [全局旗标] <子命令> [参数...]
```

| 子命令 | 说明 |
|---|---|
| `add [--type TYPE] <text>` | 新增记忆；无参数时从 stdin 读 |
| `search <query>` | 语义检索（spawn `llm`） |
| `list [选项] [N]` | 列出记忆；给定 N 时只列最后 N 条 |
| `types` | 按类型统计计数，降序输出 |
| `show <id>` | 打印记忆文件全文 |
| `forget <id>` | 删除记忆 |
| `edit <id> [--slug SLUG] [text]` | 更新正文；无 text 时从 stdin 读 |
| （空） | 打印 usage |

### 全局旗标（必须在子命令之前）

| 旗标 | 说明 |
|---|---|
| `-h, --help` | 打印 usage |
| `--version` | 打印版本号 |
| `-v, --verbose` | 调试模式，向 stderr 输出 `[mem debug] ...` |
| `--dir DIR` | 覆盖记忆目录（默认 `./.memories`） |

---

## 存储格式

目录默认 `./.memories`（`MEM_DIR` 或 `--dir` 覆盖）。文件名格式：

```
YYYY-MM-DD-HH-MM-SS_HEX8_slug.md
例：2026-09-03-21-13-10_72b37d6c_mem-this-tool-should-work.md
```

文件内容：

```markdown
---
id: 72b37d6c
summary: mem 这个工具应该可以用
type: todo
created: 2026-09-03 21:13:10
---

正文……
```

- **`id`**：8 位小写随机 hex。文件名的 slug 段由 `slugify` 生成：转小写、连续非 ASCII
  字母数字折叠为单个 `-`、去首尾 `-`、截断 80 字符。**非 ASCII 字符（如中文）会被全部丢弃**，
  纯中文正文的 slug 为空，文件名以 `_` 结尾。
- **`summary`**：正文首行截断 80 字节。
- **`type`**：见下表，缺省 `memory`。
- **`created`**：`YYYY-MM-DD HH:MM:SS`（本地时区）。
- **`updated`**：`edit` 时写入，见下。

### 类型

`todo`、`objective`、`value`、`belief`、`fact`、`preference`、`note`。
`add --type` 可写任意字符串；默认 `memory`。`list` 中 frontmatter 无 `type` 时按 `memory` 处理。

### 兼容旧格式

无 hex id 的旧文件名 `YYYY-MM-DD-HH-MM-SS_slug.md` 也能解析；此时 `list -s` 的 id 列显示
`--------`。

---

## 子命令详解

### add

```bash
mem add "记一件事"
mem add --type fact "深圳是用户常住城市"
echo "多行内容" | mem add --type note
```

创建目录（不存在时 `mkdir -p`），写文件，stdout 打印新文件名（不含 `.md`）。正文为空则报错。

多个 `--type` 只有**开头连续**的几个被识别（`while rest[j] == "--type"`），其余并入正文。

### list

```bash
mem list              # 全部，详细视图
mem list 5            # 最后 5 条
mem list -s           # 单行紧凑视图
mem list --type fact
mem list --before 2026-09-03
mem list --after 2026-09-01
mem list -s 20 --type note --after 2026-08-01
```

| 选项 | 说明 |
|---|---|
| `-s, --short` | 每行一条：`YYYY-MM-DD HH:MM  <id后8位>  [type]  summary` |
| `--type TYPE` | 按类型过滤 |
| `--before DATE` | 只保留日期 ≤ DATE（`YYYY-MM-DD`，按字符串比较） |
| `--after DATE` | 只保留日期 ≥ DATE |
| `N` | 首位为数字的参数视为条数上限，取排序后的最后 N 条 |

详细视图每行输出 `id  YYYY-MM-DD HH:MM  [type]` + summary + 文件路径；非 TTY 时自动去掉 ANSI 颜色。
目录为空时向 stderr 打印 `No memories stored.`。

### types

按计数降序（同计数按类型名升序）输出 `  NN  type`。类型取自 frontmatter 的 `type` 字段，
没有该字段的记忆按空名统计（`list` 里则按 `memory` 显示）。

### show

```bash
mem show 72b37d6c      # hex id（4-8 位，前缀即可）
mem show 2026-09-03-21-13-10_72b37d6c_mem-this-tool-should-work
```

id 解析规则：

1. 参数是 4–8 位小写 hex → 在所有文件名（去掉 `.md`）里匹配子串 `_<id>`。命中 1 条即返回；
   命中多条报 `Ambiguous`。
2. 否则按 `<dir>/<id>.md` 精确匹配文件。
3. 都失败报 `Memory not found: <id> (use hex ID prefix from 'mem list')`。

### forget

```bash
mem forget 72b37d6c
```

删除文件，stderr 打印 `Forgotten: <basename 去掉 .md>`。

### edit

```bash
mem edit 72b37d6c "新正文"
echo "新正文" | mem edit 72b37d6c
mem edit 72b37d6c --slug new-slug "新正文"
```

行为：

1. 保留原 `id`、`type`、`created`。
2. `summary` 按新正文首行重算。
3. `updated` 字段：原为列表则追加一项；原为单值则转成两元素列表；原本没有则写单值。
4. 文件名 slug 跟随新正文重算（`--slug` 优先），不同则 rename。

`--slug` 只在**开头**被识别。剩余参数全部按空格拼接为正文；为空则读 stdin；仍为空则报错。

成功后 stderr 打印 `Updated: <文件名去掉 .md>`（文件名变了则打印新名）。

### search

```bash
mem search "上次讨论的 C3 坑"
```

把所有记忆交给外部 `llm` 命令做语义检索，要求它只回「文件名 + summary，一行一条」。

- 依赖 **PATH 里的 `llm` 可执行文件**（本项目 `llm` target 的产物）。找不到时报错退出。
- 若设置了 `SHELLM_FAST_MODEL`，会额外传 `-m <model>`。
- 无记忆时直接输出 `No memories stored.` 并退出。
- 子进程的退出码原样透传。

---

## 配置优先级

```
./.memrc  <  环境变量  <  命令行旗标
```

`.memrc`（当前工作目录）每行 `KEY=VALUE`，`#` 开头为注释。识别的键：

| 键 | 等价于 | 说明 |
|---|---|---|
| `MEM_DIR` | `--dir` | 记忆目录，默认 `./.memories` |
| `MEM_TYPE` | `add --type` | 默认类型，默认 `memory` |
| `SHELLM_FAST_MODEL` | — | `search` 传给 `llm -m` 的模型 |
| `VERBOSE` | `-v` | 仅 `1` 视为开启 |

---

## 退出码与错误

错误统一输出 `mem: error: <msg>`，退出码 1。`search` 会透传 `llm` 的退出码。

---

## 示例

```bash
export MEM_DIR=~/notes/.memories

mem add --type fact "用户常住深圳"
mem add --type todo "给 llm/mem 写文档"
mem list -s 10
mem types
mem search "文档"

id=$(mem list -s 1 | awk 'NR==1{print $3}')   # $1=日期 $2=时间 $3=id
mem show "$id"
mem edit "$id" "内容已更新"
mem forget "$id"
```

---

## 已知限制

- `search` 依赖外部 `llm` 命令，且把全部记忆一次性塞进 prompt——记忆量大时会撞上下文上限。
- 无全文索引，`list` 过滤是线性扫描 + 字符串比较。
- `slugify` 只认 ASCII 字母数字，非 ASCII 字符全部丢弃，纯中文正文的 slug 为空。
- `add --type` / `edit --slug` 只解析开头的连续旗标，写在正文中间会被当正文。
- 无并发保护；多进程同时写同一目录存在竞争。
