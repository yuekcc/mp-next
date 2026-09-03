// memstore — mem CLI 的核心模块：配置、文件名解析、frontmatter 解析、
// 内存文件定位与随机 ID 生成。复刻 headlong/bin/mem（bash 版）的行为。
module memstore;

import std::io, std::io::file, std::io::path, std::os::env, std::os::process, std::os::win32;
import std::collections::list, std::sort, std::math::random, std::time::datetime, libc;

const String VERSION = "0.1.0";
const String DEFAULT_DIR = ".memories";

// ===========================================================================
// 错误与调试
// ===========================================================================

macro void die(String $format, args...)
{
	io::eprintfn("mem: error: " +++ $format, ...args);
	libc::exit(1);
}

macro void debug(Config* cfg, String $format, args...)
{
	if (cfg.verbose)
	{
		io::eprintfn("[mem debug] " +++ $format, ...args);
	}
}

// ===========================================================================
// 终端颜色（非 tty 时全部为空串）
// ===========================================================================

struct ColorSet
{
	String id;    // 粗体黄色，hex id
	String ctype; // 青色，type 标签
	String dim;   // 暗色，路径
	String reset;
}

fn ColorSet init_colors()
{
	ColorSet c; // 零初始化 = 全空串
	if (io::stdout().isatty())
	{
		c.id = "\e[1;33m";
		c.ctype = "\e[36m";
		c.dim = "\e[2m";
		c.reset = "\e[0m";
	}
	return c;
}

// ===========================================================================
// 配置：rc 文件 < 环境变量 < 命令行旗标
// ===========================================================================

struct Config
{
	String dir;        // MEM_DIR（默认 ./.memories）
	bool verbose;      // VERBOSE
	String mem_type;   // MEM_TYPE（add 的默认类型）
	String fast_model; // SHELLM_FAST_MODEL（search 用）
	ColorSet colors;
}

fn void Config.init(&self)
{
	self.dir = DEFAULT_DIR;
	self.mem_type = "memory";
	self.colors = init_colors();

	// 1) .memrc（当前目录）先加载（优先级最低）
	load_memrc(self);

	// 2) 环境变量覆盖 rc 文件
	String[4] keys = { "MEM_DIR", "MEM_TYPE", "SHELLM_FAST_MODEL", "VERBOSE" };
	foreach (k : keys)
	{
		if (try v = env::tget_var(k))
		{
			apply_setting(self, k, v);
		}
	}
}

fn void apply_setting(Config* cfg, String key, String value)
{
	if (key == "MEM_DIR")
	{
		cfg.dir = value.copy(mem);
	}
	else if (key == "MEM_TYPE")
	{
		cfg.mem_type = value.copy(mem);
	}
	else if (key == "SHELLM_FAST_MODEL")
	{
		cfg.fast_model = value.copy(mem);
	}
	else if (key == "VERBOSE")
	{
		cfg.verbose = value == "1";
	}
}

// 加载当前目录下的 .memrc：每行 KEY=VALUE，# 开头为注释。
// （bash 版是 source；此处按 KEY=VALUE 解析，覆盖等价键。）
fn void load_memrc(Config* cfg)
{
	if (!file::exists(".memrc")) return;
	char[]? content_r = file::load(tmem, ".memrc");
	if (catch content_r) return;
	String content = (String)content_r;
	sz pos = 0;
	while (pos < content.len)
	{
		sz nl = content.index_of_char_from('\n', pos) ?? content.len;
		String line = content[pos:nl - pos];
		pos = nl + 1;
		if (line.ends_with("\r")) line = line[..line.len - 2];
		if (line.len == 0 || line[0] == '#') continue;
		sz? eq = line.index_of_char('=');
		if (try eq)
		{
			apply_setting(cfg, line[..eq - 1], tail_from(line, eq + 1));
		}
	}
}

// ===========================================================================
// 字符串小工具
// ===========================================================================

// 取 s 从 from 到末尾（越界安全）。
fn String tail_from(String s, sz from)
{
	if (from >= s.len) return "";
	return s[from:s.len - from];
}

// 取 s 前 n 个字符（越界安全）。
fn String cut_to(String s, sz n)
{
	if (n > s.len) n = s.len;
	return s[:n];
}

// 取 s 从 start 开始的 len 个字符（越界安全）。
fn String mid_of(String s, sz start, sz len)
{
	if (start >= s.len) return "";
	sz avail = s.len - start;
	return s[start:(len < avail ? len : avail)];
}

fn sz cmp_strings(String a, String b)
{
	return a.compare_to(b);
}

fn String[] tail_slice(String[] s, usz from)
{
	if (from >= s.len) { String[] e; return e; }
	return s[from:s.len - from];
}

fn bool str_gt(String a, String b)
{
	return a.compare_to(b) > 0;
}

// tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | 去首尾 '-' | 前 80 字符
fn String slugify(Allocator allocator, String text)
{
	DString out = dstring::new(tmem);
	bool last_dash = true; // 抑制前导 '-'
	foreach (c : text)
	{
		char l = (c >= 'A' && c <= 'Z') ? (char)(c + 32) : c;
		bool alnum = (l >= 'a' && l <= 'z') || (l >= '0' && l <= '9');
		if (alnum)
		{
			out.append_char(l);
			last_dash = false;
		}
		else if (!last_dash)
		{
			out.append_char('-');
			last_dash = true;
		}
	}
	String s = out.str_view();
	if (s.len > 0 && s[s.len - 1] == '-') s = s[..s.len - 2];
	return cut_to(s, 80).copy(allocator);
}

// 首行的前 max_chars 字节（summary 用）。
fn String first_line_cut(String text, sz max_chars)
{
	sz nl = text.index_of_char('\n') ?? text.len;
	return cut_to(text, nl > max_chars ? max_chars : nl);
}

// ===========================================================================
// 文件名解析：YYYY-MM-DD-HH-MM-SS_HEXID_slug（旧格式无 HEXID）
// ===========================================================================

struct NameParts
{
	String ts;   // 2025-01-01-12-00-00
	String id;   // 8 位 hex（旧格式为空）
	String slug;
}

fn bool looks_like_ts(String s)
{
	if (s.len != 19) return false;
	foreach (i, c : s)
	{
		bool dash_pos = i == 4 || i == 7 || i == 10 || i == 13 || i == 16;
		if (dash_pos)
		{
			if (c != '-') return false;
		}
		else if (c < '0' || c > '9')
		{
			return false;
		}
	}
	return true;
}

fn bool is_hex8(String s)
{
	if (s.len != 8) return false;
	foreach (c : s)
	{
		if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
	}
	return true;
}

// 查询用 hex id：4-8 位十六进制。
fn bool is_hex_id(String id)
{
	if (id.len < 4 || id.len > 8) return false;
	foreach (c : id)
	{
		if (!((c >= '0' && c <= '9') || (c >= 'a' && c <= 'f'))) return false;
	}
	return true;
}

fn NameParts parse_filename(String base)
{
	NameParts np;
	// 新格式：19 位时间戳 _ 8 位 hex _ slug
	if (base.len > 20 && base[19] == '_' && looks_like_ts(base[..18]))
	{
		String rest = tail_from(base, 20);
		sz? us = rest.index_of_char('_');
		if (try us)
		{
			if (is_hex8(rest[..us - 1]))
			{
				np.ts = base[..18];
				np.id = rest[..us - 1];
				np.slug = tail_from(rest, us + 1);
				return np;
			}
		}
	}
	// 旧格式：时间戳_slug（无 hex id；没有 '_' 时 ts/slug 都等于 base，同 bash）
	np.id = "";
	sz? u = base.index_of_char('_');
	if (try u)
	{
		np.ts = base[..u - 1];
		np.slug = tail_from(base, u + 1);
	}
	else
	{
		np.ts = base;
		np.slug = base;
	}
	return np;
}

// ===========================================================================
// frontmatter 解析
// ===========================================================================

// 读取文件中第一个 frontmatter 块（两个 --- 之间）的原始行列表。
fn String[] frontmatter_lines(String file)
{
	String[] empty;
	char[]? content_r = file::load(tmem, file);
	if (catch content_r) return empty;
	String content = (String)content_r;

	List{String} lines;
	lines.init(tmem);
	bool in_fm = false;
	sz pos = 0;
	while (pos < content.len)
	{
		sz nl = content.index_of_char_from('\n', pos) ?? content.len;
		String line = content[pos:nl - pos];
		pos = nl + 1;
		if (line.ends_with("\r")) line = line[..line.len - 2];
		if (line == "---")
		{
			if (in_fm) break;
			in_fm = true;
		}
		else if (in_fm)
		{
			lines.push(line.copy(tmem));
		}
	}
	return lines.to_array(tmem);
}

// 提取 frontmatter 字段值（首个匹配行；去掉首尾成对引号）。字段不存在时返回 fault。
fn String? frontmatter_field(String file, String field)
{
	String[] lines = frontmatter_lines(file);
	foreach (line : lines)
	{
		if (line.starts_with(field) && line.len > field.len && line[field.len] == ':')
		{
			String v = tail_from(line, field.len + 1).trim_left();
			if (v.len >= 2)
			{
				char f = v[0];
				char b = v[v.len - 1];
				if ((f == '"' || f == '\'') && (b == '"' || b == '\''))
				{
					v = v[1:v.len - 2];
				}
			}
			return v.copy(mem);
		}
	}
	return NOT_FOUND~;
}

// ===========================================================================
// 文件列表与查找
// ===========================================================================

// 列出 MEM_DIR 下所有 .md 文件（完整路径，字典序，同 bash glob）。
// 目录不存在或读取失败时返回空列表。
fn String[] list_memory_files(String dir)
{
	String[] empty;
	Path? d_r = path::new(tmem, dir);
	if (catch d_r) return empty;
	Path d = d_r;

	PathList? listing_r = path::ls(tmem, d, true, false, "*.md");
	if (catch listing_r) return empty;
	PathList listing = listing_r;

	String[] result = (String[])listing.to_array(mem);
	foreach (&p : result)
	{
		*p = string::format(mem, "%s/%s", dir, (String)*p);
	}
	sort::quicksort(result, &cmp_strings);
	return result;
}

// 解析名称/前缀/hex id 为内存文件路径（找不到时 die）。
fn String find_memory(Config* cfg, String id)
{
	if (is_hex_id(id))
	{
		int count = 0;
		String first = "";
		foreach (f : list_memory_files(cfg.dir))
		{
			// 同 bash basename "$_f" .md：去掉目录与 .md 后缀
			String base = (f.file_tbasename() ?? "").strip_suffix(".md");
			if (base.contains(string::tformat("_%s", id)))
			{
				count++;
				if (count == 1) first = base.copy(mem);
			}
		}
		if (count == 1)
		{
			return string::format(mem, "%s/%s.md", cfg.dir, first);
		}
		if (count > 1)
		{
			die("Ambiguous: '%s' matches multiple memories", id);
		}
	}
	String exact = string::format(mem, "%s/%s.md", cfg.dir, id);
	if (file::exists(exact)) return exact;
	die("Memory not found: %s (use hex ID prefix from 'mem list')", id);
	return ""; // 不可达：die 已退出进程，仅为满足返回检查
}

// ===========================================================================
// 时间与随机 ID
// ===========================================================================

fn TzDateTime now_local()
{
	return datetime::now().to_local();
}

// mkdir -p（已存在时静默跳过）。
fn void path_mkdir(String dir)
{
	Path d = path::new(tmem, dir)!!;
	if (!path::is_dir(d))
	{
		(void)path::mkdir(d, true);
	}
}

// YYYY-MM-DD-HH-MM-SS（文件名用）
fn String now_filename_ts()
{
	TzDateTime t = now_local();
	return string::tformat("%04d-%02d-%02d-%02d-%02d-%02d",
		t.year, (int)t.month + 1, (int)t.day, (int)t.hour, (int)t.min, (int)t.sec);
}

// "YYYY-MM-DD HH:MM:SS"（frontmatter created/updated 用）
fn String now_created_ts()
{
	TzDateTime t = now_local();
	return string::tformat("%04d-%02d-%02d %02d:%02d:%02d",
		t.year, (int)t.month + 1, (int)t.day, (int)t.hour, (int)t.min, (int)t.sec);
}

// 8 位小写 hex 随机 id（对应 head -c4 /dev/urandom）。
fn String random_hex8()
{
	const char[16] HEXDIGITS = { '0', '1', '2', '3', '4', '5', '6', '7', '8', '9', 'a', 'b', 'c', 'd', 'e', 'f' };
	char[8] buf @noinit;
	for (int i = 0; i < 8; i++)
	{
		buf[i] = HEXDIGITS[random::rand(16)];
	}
	// 注意：不能返回栈数组的切片视图（悬空），用 tformat 落到 tmem。
	return string::tformat("%c%c%c%c%c%c%c%c",
		buf[0], buf[1], buf[2], buf[3], buf[4], buf[5], buf[6], buf[7]);
}

// ===========================================================================
// 进程 stdin 处理
// ===========================================================================

// 读完整个 stdin（无输入管道时返回空串）。
// 注意：不用 io::read_fully——它对管道走 available() 预分配路径，拿到 0 就直接返回空。
fn String read_stdin_all()
{
	DString buf = dstring::new(tmem);
	char[4096] tmp @noinit;
	File* in = io::stdin();
	while (true)
	{
		sz? n = in.read(&tmp);
		if (catch n) break;
		if (n == 0) break;
		buf.append_bytes(tmp[:n]);
	}
	return buf.str_view();
}

// 关闭子进程 stdin（写完搜索语料后触发 EOF）。
fn void close_stdin(Process* process)
{
	if (process.stdin_file)
	{
		libc::fclose(process.stdin_file);
		process.stdin_file = null;
	}
	$if env::WIN32:
		if (process.hStdInput)
		{
			win32::closeHandle(process.hStdInput);
			process.hStdInput = null;
		}
	$endif
}
