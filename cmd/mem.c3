// mem — CLI memory store（C3 版，复刻 headlong/bin/mem 行为）
// 每条记忆是一个带 YAML frontmatter 的 markdown 文件；search 走外部 llm 命令。
module mem_cli;

import std::io, std::io::file, std::os::process, std::collections::list, std::sort, libc, std::core::string;
import memstore;
import util;

const String USAGE = "mem — CLI memory store\n" +++ "\n" +++ "Usage:\n"
	+++ "  mem add [--type TYPE] <text>   Add a memory (or pipe text via stdin)\n"
	+++ "  mem search <query>             Semantic search via shellm\n"
	+++ "  mem list [options] [N]         List memories (last N if given)\n"
	+++ "  mem types                      List memory types with counts\n"
	+++ "  mem show <id>                  Show a memory's full contents\n"
	+++ "  mem forget <id>                Delete a memory by hex ID\n"
	+++ "  mem edit <id> [--slug SLUG] <text>  Update body (or pipe via stdin)\n"
	+++ "\n"
	+++ "List options:\n"
	+++ "  -s, --short        Concise one-line-per-memory view\n"
	+++ "  --type TYPE        Filter by type (e.g. --type fact)\n"
	+++ "  --before DATE      Show memories on or before DATE (YYYY-MM-DD)\n"
	+++ "  --after DATE       Show memories on or after DATE (YYYY-MM-DD)\n"
	+++ "\n"
	+++ "Types:\n"
	+++ "  todo, objective, value, belief, fact, preference, note (default: memory)\n"
	+++ "\n"
	+++ "Options:\n"
	+++ "  --dir DIR          Override memory directory (default: ./.memories)\n"
	+++ "  -v, --verbose      Verbose/debug mode\n"
	+++ "  -h, --help         Show help\n"
	+++ "  --version          Show version\n"
	+++ "\n"
	+++ "Environment:\n"
	+++ "  MEM_DIR          Override memory directory (default: ./.memories)\n"
	+++ "  LLM_API_URL      Endpoint passed to llm --api-url in `mem search`\n"
	+++ "  LLM_API_KEY      Token passed to llm --api-key in `mem search`\n";

const String SEARCH_PROMPT = "You are a semantic search engine for memory files. Each memory has a "
	+++ "filename header (=== filename ===), YAML frontmatter (summary, type), and "
	+++ "a body. Return ONLY the filenames and summaries of semantically matching "
	+++ "memories, one per line. If nothing matches, say 'No matches found.'";

// ===========================================================================
// add
// ===========================================================================

fn void action_add(Config* cfg, String text)
{
	if (text.len == 0) memstore::die("No text provided");

	(void)memstore::path_mkdir(cfg.dir);

	String ts = memstore::now_filename_ts();
	String hex = memstore::random_hex8();
	String slug = memstore::slugify(mem, text);
	String filename = string::format(mem, "%s_%s_%s", ts, hex, slug);
	String summary = memstore::first_line_cut(text, 80);
	String created = memstore::now_created_ts();

	DString body = dstring::new(tmem);
	body.appendf(
		"---\nid: %s\nsummary: %s\ntype: %s\ncreated: %s\n---\n\n%s\n",
		hex,
		summary,
		cfg.mem_type,
		created,
		text
	);
	String path = string::format(mem, "%s/%s.md", cfg.dir, filename);
	file::save(path, body.str_view())!!;

	memstore::debug(cfg, "Created: %s", path);
	io::printfn("%s", filename);
}

// ===========================================================================
// search
// ===========================================================================

fn void action_search(Config* cfg, String query)
{
	String[] files = memstore::list_memory_files(cfg.dir);
	if (files.len == 0)
	{
		io::eprintn("No memories stored.");
		return;
	}

	// 拼接语料：=== 文件名 === 为头，后接文件全文。
	DString corpus = dstring::new(tmem);
	foreach (f : files)
	{
		String base = f.file_tbasename() ?? "";
		corpus.appendf("=== %s ===\n", base);
		char[]? c = file::load(tmem, f);
		if (try cc = c) corpus.append_bytes(cc);
		corpus.append("\n\n");
	}

	List{String} argv;
	argv.init(tmem);
	argv.push("llm");
	if (cfg.fast_model.len > 0)
	{
		argv.push("-m");
		argv.push(cfg.fast_model);
	}
	// llm 不读环境变量（见 docs/adr/0002）：url/key 从 mem 自身配置
	// （.memrc / 环境变量）翻译成开关传给子进程。
	if (cfg.api_url.len > 0)
	{
		argv.push("--api-url");
		argv.push(cfg.api_url);
	}
	if (cfg.api_key.len > 0)
	{
		argv.push("--api-key");
		argv.push(cfg.api_key);
	}
	argv.push("-s");
	argv.push(SEARCH_PROMPT);
	String[] cmd = argv.to_array(tmem);

	Process? pr = process::spawn(cmd, STDERR_TO_STDOUT | INHERIT_ENV);
	if (catch err = pr)
	{
		io::eprintfn("mem: error: failed to run 'llm' (is shellm installed?): %s", err);
		libc::exit(1);
	}
	Process p = pr!!;
	defer (void)p.destroy();

	// 语料经 stdin 传入，避免命令行长度限制；写完即关 stdin 触发 EOF。
	(void)p.write_stdin(string::tformat("Search these memories for: %s\n\n%s", query, corpus.str_view()));
	util::close_stdin(&p);

	@pool()
	{
		DString out = dstring::new(tmem);
		char[4096] buf @noinit;
		while (true)
		{
			sz n = p.read_stdout(&buf, buf.len)!!;
			if (n == 0) break;
			out.write(buf[:n])!!;
		}
		int code = p.join()!!;
		io::print(out.str_view());
		if (code != 0) libc::exit(code);
	};
}

// ===========================================================================
// list
// ===========================================================================

fn String arg_value(String[] args, usz* i, String flag)
{
	if (*i + 1 >= args.len) memstore::die("%s requires a value", flag);
	String v = args[*i + 1];
	*i += 2;
	return v;
}

fn void print_list_short(String display_ts, NameParts np, String mtype, String summary)
{
	// bash ${id:---------}：有 id 取末 8 位，无 id 显示 8 个 '-'
	String short_id = "--------";
	if (np.id.len > 0) short_id = memstore::mid_of(np.id, np.id.len > 8 ? np.id.len - 8 : 0, 8);
	io::printfn("%s  %s  %-12s %s", display_ts, short_id, string::tformat("[%s]", mtype), summary);
}

fn void print_list_verbose(Config* cfg, String file, String display_ts, NameParts np, String mtype)
{
	String id_display;
	if (np.id.len > 0)
	{
		id_display = string::tformat("%s%s%s", cfg.colors.id, np.id, cfg.colors.reset);
	}
	else
	{
		id_display = string::tformat("%s--------%s", cfg.colors.dim, cfg.colors.reset);
	}
	io::printfn("%s  %s  %s[%s]%s", id_display, display_ts, cfg.colors.ctype, mtype, cfg.colors.reset);
	String summary = "";
	if (try s = memstore::frontmatter_field(file, "summary")) summary = s;
	if (summary.len > 0) io::printfn("    %s", summary);
	io::printfn("    %s%s%s", cfg.colors.dim, file, cfg.colors.reset);
}

fn void action_list(Config* cfg, String[] args)
{
	int limit = 0;
	bool short_mode = false;
	String filter_type = "";
	String filter_before = "";
	String filter_after = "";

	usz i = 0;
	while (i < args.len)
	{
		String a = args[i];
		if (a == "-s" || a == "--short")
		{
			short_mode = true;
			i++;
		}
		else if (a == "--type")
		{
			filter_type = arg_value(args, &i, "--type");
		}
		else if (a == "--before")
		{
			filter_before = arg_value(args, &i, "--before");
		}
		else if (a == "--after")
		{
			filter_after = arg_value(args, &i, "--after");
		}
		else if (a.len > 0 && a[0] >= '0' && a[0] <= '9')
		{
			limit = a.to_int() ?? 0;
			i++;
		}
		else
		{
			memstore::die("Unknown list option: %s", a);
		}
	}

	String[] files = memstore::list_memory_files(cfg.dir);
	if (files.len == 0)
	{
		io::eprintn("No memories stored.");
		return;
	}

	// 限制为最后 N 条
	if (limit > 0)
	{
		usz lim = (usz)limit;
		if (lim > files.len) lim = files.len;
		if (lim < files.len) files = files[files.len - lim:lim];
	}

	foreach (f : files)
	{
		String base = f.file_tbasename() ?? "";
		NameParts np = memstore::parse_filename(base);

		String mtype = "";
		if (try t = memstore::frontmatter_field(f, "type")) mtype = t;
		if (mtype.len == 0) mtype = "memory";

		if (filter_type.len > 0 && mtype != filter_type) continue;

		String file_date = memstore::cut_to(np.ts, 10); // YYYY-MM-DD
		if (filter_before.len > 0 && memstore::str_gt(file_date, filter_before)) continue;
		if (filter_after.len > 0 && memstore::str_gt(filter_after, file_date)) continue;

		String display_ts = string::tformat(
			"%s %s:%s",
			memstore::cut_to(np.ts, 10),
			memstore::mid_of(np.ts, 11, 2),
			memstore::mid_of(np.ts, 14, 2)
		);

		if (short_mode)
		{
			String summary = "";
			if (try s = memstore::frontmatter_field(f, "summary")) summary = s;
			if (summary.len == 0) summary = np.slug;
			print_list_short(display_ts, np, mtype, summary);
		}
		else
		{
			print_list_verbose(cfg, f, display_ts, np, mtype);
		}
	}
}

// ===========================================================================
// types
// ===========================================================================

struct TypeCount
{
	int count;
	String type;
}

fn sz cmp_type_count(TypeCount a, TypeCount b)
{
	if (a.count != b.count) return (sz)(b.count - a.count);
	return a.type.compare_to(b.type);
}

fn void action_types(Config* cfg)
{
	String[] files = memstore::list_memory_files(cfg.dir);

	List{TypeCount} entries;
	entries.init(tmem);
	foreach (f : files)
	{
		String t = "";
		if (try tv = memstore::frontmatter_field(f, "type")) t = tv;
		bool found = false;
		foreach (&e : entries)
		{
			if (e.type == t)
			{
				e.count++;
				found = true;
				break;
			}
		}
		if (!found) entries.push({ 1, t.copy(tmem) });
	}

	TypeCount[] arr = entries.to_array(tmem);
	sort::quicksort(arr, &cmp_type_count);
	foreach (tc : arr)
	{
		io::printfn("%4d  %s", tc.count, tc.type);
	}
}

// ===========================================================================
// show / forget
// ===========================================================================

fn void action_show(Config* cfg, String name)
{
	String file = memstore::find_memory(cfg, name);
	char[]? content = file::load(mem, file);
	if (catch content) memstore::die("cannot read: %s", file);
	(void)io::print((String)content);
}

fn void action_forget(Config* cfg, String name)
{
	String file = memstore::find_memory(cfg, name);
	memstore::debug(cfg, "Deleting: %s", file);
	file::delete(file)!!;
	io::eprintfn("Forgotten: %s", basename_noext(file));
}

// 去掉目录与 .md 后缀的文件名。
fn String basename_noext(String file)
{
	String b = file.file_tbasename() ?? "";
	return b.strip_suffix(".md");
}

// ===========================================================================
// edit
// ===========================================================================

fn void action_edit(Config* cfg, String name, String[] args)
{
	String file = memstore::find_memory(cfg, name);

	String slug_override = "";
	usz i = 0;
	while (i < args.len && args[i] == "--slug")
	{
		slug_override = arg_value(args, &i, "--slug");
	}

	// 剩余参数以空格拼接为正文；为空则读 stdin。
	DString tb = dstring::new(tmem);
	for (; i < args.len; i++)
	{
		if (tb.len() > 0) tb.append(" ");
		tb.append(args[i]);
	}
	String text = tb.str_view();
	if (text.len == 0) text = util::read_stdin_all();
	if (text.len == 0) memstore::die("No text provided");

	String now = memstore::now_created_ts();

	String summary = memstore::first_line_cut(text, 80);
	String mtype = "";
	if (try t = memstore::frontmatter_field(file, "type")) mtype = t;
	String created = "";
	if (try t = memstore::frontmatter_field(file, "created")) created = t;
	String id = "";
	if (try t = memstore::frontmatter_field(file, "id")) id = t;

	// updated 字段：已是列表则追加，单值转列表，否则新建单值。
	String updated_single = "";
	DString list_items = dstring::new(tmem);
	foreach (l : memstore::frontmatter_lines(file))
	{
		if (l.starts_with("  - "))
		{
			list_items.append("\n");
			list_items.append(l);
		}
		else if (l.starts_with("updated:"))
		{
			updated_single = memstore::tail_from(l, 8).trim_left();
		}
	}

	DString updated_block = dstring::new(tmem);
	if (list_items.len() > 0)
	{
		updated_block.append("updated:");
		updated_block.append(list_items.str_view());
		updated_block.appendf("\n  - %s", now);
	}
	else if (updated_single.len > 0)
	{
		updated_block.appendf("updated:\n  - %s\n  - %s", updated_single, now);
	}
	else
	{
		updated_block.appendf("updated: %s", now);
	}

	DString content = dstring::new(tmem);
	content.append("---\n");
	if (id.len > 0) content.appendf("id: %s\n", id);
	content.appendf("summary: %s\n", summary);
	content.appendf("type: %s\n", mtype);
	content.appendf("created: %s\n", created);
	content.append(updated_block.str_view());
	content.append("\n---\n\n");
	content.append(text);
	content.append("\n"); // 同 bash heredoc：正文以换行结尾
	file::save(file, content.str_view())!!;

	// 文件名 slug 跟随新正文更新（--slug 优先；经 slugify 清洗防止换行/路径符）。
	String base = basename_noext(file);
	NameParts np = memstore::parse_filename(base);
	String new_slug = (slug_override.len > 0) ? memstore::slugify(mem, slug_override) : memstore::slugify(mem, text);
	if (new_slug.len > 0 && new_slug != np.slug)
	{
		String new_file = string::format(mem, "%s/%s_%s_%s.md", cfg.dir, np.ts, np.id, new_slug);
		if (libc::rename(file.zstr_copy(tmem), new_file.zstr_copy(tmem)) != 0)
		{
			memstore::die("rename failed: %s -> %s", file, new_file);
		}
		file = new_file;
	}

	memstore::debug(cfg, "Updated: %s", file);
	io::eprintfn("Updated: %s", basename_noext(file));
}

// ===========================================================================
// 入口与分发
// ===========================================================================

// 把剩余参数以空格拼接（同 bash "$*"）。
fn String join_args(String[] args)
{
	DString b = dstring::new(tmem);
	foreach (a : args)
	{
		if (b.len() > 0) b.append(" ");
		b.append(a);
	}
	return b.str_view().copy(mem);
}

fn void main(String[] args)
{
	Config cfg;
	cfg.init();

	// 全局旗标（必须位于子命令之前，同 bash 版）
	usz i = 1;
	while (i < args.len)
	{
		String a = args[i];
		if (a == "-h" || a == "--help")
		{
			io::print(USAGE);
			return;
		}
		if (a == "--version")
		{
			io::printfn("mem %s", memstore::VERSION);
			return;
		}
		if (a == "-v" || a == "--verbose")
		{
			cfg.verbose = true;
			i++;
			continue;
		}
		if (a == "--dir")
		{
			if (i + 1 >= args.len) memstore::die("--dir requires a path");
			cfg.dir = args[i + 1].copy(mem);
			i += 2;
			continue;
		}
		break;
	}

	if (i >= args.len)
	{
		io::print(USAGE);
		return;
	}

	String cmd = args[i];
	i++;
	String[] rest = memstore::tail_slice(args, i);

	switch (cmd)
	{
		case "add":
			// add 子命令的 --type 旗标
			usz j = 0;
			while (j < rest.len && rest[j] == "--type")
			{
				cfg.mem_type = arg_value(rest, &j, "--type").copy(mem);
			}
			String add_text = join_args(rest[j:rest.len - j]);
			// 无参数时从 stdin 读取（同 bash 版）
			if (add_text.len == 0) add_text = util::read_stdin_all();
			action_add(&cfg, add_text);
		case "search":
			if (rest.len < 1) memstore::die("Usage: mem search <query>");
			action_search(&cfg, join_args(rest));
		case "list":
			action_list(&cfg, rest);
		case "types":
			action_types(&cfg);
		case "show":
			if (rest.len < 1) memstore::die("Usage: mem show <id>");
			action_show(&cfg, rest[0]);
		case "forget":
			if (rest.len < 1) memstore::die("Usage: mem forget <id>");
			action_forget(&cfg, rest[0]);
		case "edit":
			if (rest.len < 1) memstore::die("Usage: mem edit <id> [--slug SLUG] [text]");
			action_edit(&cfg, rest[0], memstore::tail_slice(rest, 1));
		case "":
			io::print(USAGE);
		default:
			memstore::die("Unknown command: %s (try mem --help)", cmd);
	}
}
