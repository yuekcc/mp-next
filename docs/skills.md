# 技能（skills）

llmcli 会自动发现本机技能，把可用列表追加进系统提示词，模型据此自行用 Python 读取对应
`SKILL.md` 并照其执行。发现两处目录（同名时项目级覆盖全局级）：

- 全局：`~/.agents/skills/<name>/SKILL.md`
- 项目：`<当前目录>/.agents/skills/<name>/SKILL.md`

每个 `SKILL.md` 以 front matter 给出 `name` 与 `description`，其后为技能正文；三者齐全才算
一个有效 skill。用 `--list-skills` 查看当前发现的结果：

```bash
llmcli --list-skills
```

想看某次运行实际会发给端点的系统提示词（含已注入的 skill 列表），用：

```bash
llmcli --print-system-prompt
```

它不要求 `--model` / `--api-key`，也不读输入；可与 `--system-prompt` / `--system-prompt-file`
组合，验证自定义提示词与技能列表拼接后的最终结果。
