module tool;

import std::io;
import std::io::file;
import std::io::path;
import std::collections::list;
import libc;

// Windows CRT rename 在目标已存在时失败（非原子覆盖），必须用 MoveFileExW。
// 平台 extern 无条件声明（c3 0.8.3 无模块级 $if；未使用平台不引用，链接器不解析）。
extern fn int move_file_ex_w(WString old_name, WString new_name, uint flags) @cname("MoveFileExW");

const uint MOVEFILE_REPLACE_EXISTING = 0x1;

// 原子写回（对齐 Go 版 edit.go）：写 <file>.tmp → rename 原子换名 → 失败清理 tmp 并报错。
// - POSIX：libc::rename 单条原子调用，覆盖已存在目标；
// - Windows：MoveFileExW 带 MOVEFILE_REPLACE_EXISTING（Go os.Rename 同款语义）。
fn void? atomic_save(Path path_obj, String data)
{
	String tmp = string::tformat("%s.tmp", path_obj);
	file::save(tmp, data)!;

	$if env::WIN32:
		// MoveFileExW 返回 BOOL：TRUE(1)=成功，0=失败（与 POSIX rename 的 0=成功相反）
		if (move_file_ex_w(tmp.to_temp_wstring()!, path_obj.to_temp_wstring()!, MOVEFILE_REPLACE_EXISTING) == 0)
		{
			(void)libc::remove(tmp.zstr_tcopy());
			return RENAME_FILE_ERROR~;
		}
	$else
		if (libc::rename(tmp.zstr_tcopy(), path_obj.zstr_tcopy()) != 0)
		{
			(void)libc::remove(tmp.zstr_tcopy());
			return RENAME_FILE_ERROR~;
		}
	$endif
}

// 工具中间产物目录：<config_dir>/task_store（config_dir 空时回退 ~/.config/mp/task_store）。
fn Path load_store_dir(Allocator allocator, Path config_dir = (Path)"")
{
	Path store_dir;
	if (config_dir != "")
	{
		store_dir = config_dir.append(allocator, "task_store")!!;
	}
	else
	{
		Path user_home  = path::home_directory(allocator)!!;
		store_dir = user_home.append(allocator, ".config/mp/task_store")!!;
	}

	if (!path::exists(store_dir))
	{
		path::mkdir(store_dir, true)!!;
	}

	return store_dir;
}
