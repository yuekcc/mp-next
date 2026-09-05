module cmd;

import std::os::process;
import std::os::win32;
import std::io;
import std::atomic;
import log;
import util;

struct CommandResult
{
	int code;
	String output;
}

// 当前正在执行的子进程句柄/pid（Agent 单写；UI 线程在 L2 工具中断时读取并杀进程）。
// 共享可变原语之一（atomic），见 arch-next-spec 决策 2。
Atomic{ulong} g_current_child_handle;

// POSIX kill（仅 !WIN32 分支引用；无条件声明不影响 Windows 链接）
extern fn int kill(int pid, int sig) @cname("kill");
// Windows GetProcessId（仅 WIN32 分支引用）
extern fn uint get_process_id(void* handle) @cname("GetProcessId");

fn void notify_child_started(ulong handle)
{
	g_current_child_handle.store(handle);
}

fn void notify_child_finished()
{
	g_current_child_handle.store(0);
}

// L2 工具中断：杀当前子进程树。返回是否确实有子进程被杀（供 UI 区分
// CANCEL_TOOL / CANCEL_REQUEST 事件）。
// Windows：taskkill /F /T（孙进程如 sleep 继承 stdout 管道写端，单独 TerminateProcess
// 只杀 sh、管道不 EOF，read_stdout 会挂到孙进程自然退出——必须整树击杀）。
// POSIX：SIGKILL 直接杀（进程组击杀待 setpgid 支持后改进）。
// 无子进程（0）时 no-op。由 UI 线程在 Ctrl+C 时调用。
fn bool kill_current_child()
{
	ulong handle = g_current_child_handle.load();
	if (handle == 0) return false;

	$if env::WIN32:
		uint pid = get_process_id((Win32_HANDLE)(void*)handle);
		if (pid == 0) return false;
		// INHERIT_ENV 必须：无继承环境时 taskkill 报「The specified module could not be found」
		String[] args = { "taskkill", "/F", "/T", "/PID", string::tformat("%d", pid) };
		if (try p = process::spawn(args, NO_WINDOW | INHERIT_ENV))
		{
			// 击杀已发出；join 偶发失败（进程句柄被并发关闭/复用）也绝不能在这里
			// panic——L2 中断跑在 UI 线程，panic 会拖垮整个 agent。
			if (try _exit_code = p.join()) {}
			(void)p.destroy();
		}
	$else
		kill((int)handle, 9 /* SIGKILL */);
	$endif
	return true;
}

// 关闭子进程 stdin 的共享实现见 util::close_stdin（cmd/memstore/llm 单一来源）。

fn CommandResult? execute(Allocator allocator, String[] command_line)
{
	Process process = process::spawn(command_line, STDERR_TO_STDOUT | INHERIT_ENV | NO_WINDOW)!;
	defer (void)process.destroy();

	// 手工关闭 stdin，避免一直在等待输入
	util::close_stdin(&process);

	// 登记子进程（L2 中断时 UI 线程据此杀进程）；join 返回后清除。
	$if env::WIN32:
		notify_child_started((ulong)process.hProcess);
	$else
		notify_child_started((ulong)process.child);
	$endif
	defer notify_child_finished();

	@pool()
	{
		DString result = dstring::new(tmem);
		while (true)
		{
			char[512] buf @noinit;
			sz len = process.read_stdout(&buf, buf.len)!;
			if (len == 0)
			{
				break;
			}

			result.write(buf[:len])!;
		}

		int exit_code = process.join()!;
		return { .code = exit_code, .output = result.copy_str(allocator) };
	};
}

fn String? execute_to_string(Allocator allocator, String[] command_line)
{
	CommandResult cmd_result = execute(allocator, command_line)!;
	return cmd_result.output;
}
