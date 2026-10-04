module llmcli::rlm;

import std::collections::list;

// ---- 类型 ----

// 从模型回复里取出第一个 ```bash / ```sh / ``` 代码块（shellm 式 RLM 循环的核心）。
// 取出的代码串在 mem 上，由调用方释放。
struct Extract
{
	String code;      // 第一个代码块的内容；没有代码块时为空
	bool has_code;    // 是否真的找到了代码块（与 code 为空区分：空代码块 has_code=true）
	bool truncated;   // 第一个代码块之后还有其他代码块（只执行第一个）
}

// ---- 提取 ----

// 行级扫描：围栏行开块，之后第一条 trim 后恰为 ``` 的行闭块。
// 围栏行两种形态：整行以 ``` 开头（含裸 ```），或带 ```bash / ```sh / ```shell 的
// 标记围栏缀在散文行末（模型偶尔写成"……这样。```bash"）。代码块内以 ``` 开头的行
// 不当作闭块（避免代码里嵌 markdown 时早闭）。闭块后再出现围栏行只置 truncated，
// 不再收集——只有第一个块会被执行。
//
// 不做 shellm 那套 heredoc 感知与工具标记归一化：v1 只认标准围栏，模型按提示词
// 把围栏单独放一行即可；过度宽松地"把整段散文当命令跑"反而更危险。
fn Extract extract_code(String response)
{
	Extract out;
	List{String} body;
	body.init(tmem);

	bool in_block = false;
	bool closed = false;
	String[] lines = response.split(tmem, "\n");
	foreach (line : lines)
	{
		String trimmed = line.trim();
		String rtrimmed = line.trim_right();
		bool fence = trimmed.starts_with("```")
			|| rtrimmed.ends_with("```bash")
			|| rtrimmed.ends_with("```sh")
			|| rtrimmed.ends_with("```shell");

		if (closed)
		{
			// 闭块之后只要再看到围栏行，就说明还有多余代码块
			if (fence) out.truncated = true;
			continue;
		}

		if (!in_block)
		{
			if (fence)
			{
				in_block = true;
				out.has_code = true;
			}
			continue;
		}

		// 块内：精确的闭围栏才收尾；块内其他 ``` 行当代码原样保留
		if (trimmed == "```")
		{
			in_block = false;
			closed = true;
			continue;
		}
		body.push(line);
	}

	if (out.has_code)
	{
		// 去掉块内尾部的空行，避免脚本末尾多出无意义换行（不影响语义，仅整洁）
		while (body.len() && body.get(body.len() - 1).trim().len == 0) (void)body.pop();
		DString joined = dstring::new(tmem);
		foreach (line : body)
		{
			joined.append(line);
			joined.append("\n");
		}
		out.code = joined.str_view().copy(mem);
	}

	body.free();
	return out;
}
