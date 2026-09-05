// 通用小工具集合（module util）。
//
// mp-next 把 mini_pi 的 src/util/*.c3 摊平成单文件（与 src/cmd.c3 同一约定：
// 模块名即文件名，不再有 util::* 子模块）。这里只放被 src/tool 实际引用的符号：
// 行尾归一化 + hashline 锚点管线、时间戳 id。
module util;

import std::io;
import std::io::file;
import std::io::path;
import std::os::process;
import std::os::win32;
import std::time::datetime;
import std::atomic;
import libc;

// FNV-1a 32 位哈希参数
const uint FNV_OFFSET_32 = 0x811c9dc5; // 2166136261
const uint FNV_PRIME_32  = 0x01000193; // 16777619

// 锚点字母表（对齐 oh-my-pi）：最低字节拆成两个 4-bit nibble 后映射
const String HASH_ALPHABET = "ZPMQVRWSNKTXJBYH";

// hashline 输出格式（read() 产出、hash_edit() 消费的契约，单一来源）：
//   行号:哈希|内容
const String HASH_LINE_FORMAT = "%d:%s|%s\n";

// 跨进程唯一性：并发进程同秒会得到相同时间戳，必须追加 pid 区分。
// 无条件声明、仅在对应平台分支引用（模式见 cmd.c3）。
extern fn uint get_current_pid() @cname("GetCurrentProcessId"); // Windows
extern fn int getpid(); // POSIX

// 进程内单调递增序号：解决同一进程内同秒并发的 id 碰撞。零填充定宽，
// 保证同秒内字典序递增。
Atomic{int} g_timestamp_seq;

fn String normalize_line_endings(Allocator allocator, String str)
{
	return str.replace(allocator, "\r\n", "\n");
}

// 本地时间戳，格式 YYYYMMDD_HHMMSS（session id / 文件名 / 各类 id 统一用本地时间）。
fn String timestamp(Allocator allocator, DateTime dt)
{
	dt = dt.to_local();
	return string::format(
		allocator,
		"%04d%02d%02d_%02d%02d%02d",
		dt.year,
		dt.month.ordinal + 1,
		dt.day,
		dt.hour,
		dt.min,
		dt.sec
	);
}

fn String timestamp_id(Allocator allocator)
{
	int seq = g_timestamp_seq.add(1);
	String ts = timestamp(tmem, datetime::now());
	$if env::WIN32:
		return string::format(allocator, "%s_%04d_%d", ts, seq, (int)get_current_pid());
	$else
		return string::format(allocator, "%s_%04d_%d", ts, seq, getpid());
	$endif
}

// ===========================================================================
// 子进程 stdin（cmd / memstore / llm 共用，单一来源）
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
// 注意必须传指针：进程退出后 std 的 join()/destroy() 还会再查一次这些字段，
// 按值传会让调用方的 stdin_file/hStdInput 保留「已关闭」的悬空句柄，导致重复
// close（Windows 句柄值被复用时会把不相干进程的句柄关掉 → 偶发 PROCESS_JOIN_FAILED）。
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

// 锚点契约的基础管线：加载文件 → 归一化行尾 → 按 \n 切行。
// read() 与 hash_edit() 必须对同一文件得到字节一致的行数组，锚点才成立——
// 本函数是唯一入口，避免两处管线漂移。
fn String[]? load_lines(Allocator allocator, String file_path)
{
	Path path_obj = path::new(tmem, file_path)!;
	String content = (String)file::load_path(tmem, path_obj)!;
	String normalized_content = normalize_line_endings(tmem, content);
	return normalized_content.split(allocator, "\n");
}

// 判断一行是否含有字母或数字
fn bool has_alnum(String s)
{
	foreach (b : s)
	{
		if ((b >= 'a' && b <= 'z') || (b >= 'A' && b <= 'Z') || (b >= '0' && b <= '9'))
		{
			return true;
		}
	}
	return false;
}

// 计算单行的内容哈希锚点（2 字符）。
// 算法对齐 oh-my-pi 的 hashline：
//   1. 去掉行尾 \r 与行尾空白
//   2. 对归一化字节做 FNV-1a 32 位哈希
//   3. 取最低字节，拆成两个 4-bit nibble，映射到 HASH_ALPHABET
//   4. 无字母数字的行（空行、{、} 等）额外把 1-based 行号折叠进哈希状态，
//      保证不同位置的同构行得到不同锚点
// 注意：模型读取时看到的锚点由同一函数生成，因此只需本构建内自洽即可，
//       不要求跨平台/跨版本一致。
fn String line_hash(Allocator allocator, String line, usz line_num)
{
	// 去掉行尾 \r
	String trimmed = line;
	if (trimmed.len > 0 && trimmed[trimmed.len - 1] == '\r')
	{
		trimmed = trimmed[:trimmed.len - 1];
	}
	// 去掉行尾空白（空格、tab）
	while (trimmed.len > 0 &&
	       (trimmed[trimmed.len - 1] == ' ' || trimmed[trimmed.len - 1] == '\t'))
	{
		trimmed = trimmed[:trimmed.len - 1];
	}

	uint h = FNV_OFFSET_32;

	if (!has_alnum(trimmed))
	{
		// 把行号按字节折叠进哈希状态，使同构行在不同位置得到不同锚点
		usz n = line_num;
		while (n > 0)
		{
			h ^= (uint)(n & 0xff);
			h *= FNV_PRIME_32;
			n >>= 8;
		}
	}

	foreach (b : trimmed)
	{
		h ^= (uint)b;
		h *= FNV_PRIME_32;
	}

	char low = (char)(h & 0xff);
	usz hi = (usz)((low >> 4) & 0xf);
	usz lo = (usz)(low & 0xf);

	DString buf = dstring::new(allocator);
	buf.append(HASH_ALPHABET[hi]);
	buf.append(HASH_ALPHABET[lo]);
	return buf.copy_str(allocator);
}
