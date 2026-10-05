module llmcli::winjob;

// Job Object 封装：把子进程挂进"句柄关闭即杀全家"（KILL_ON_JOB_CLOSE）的 job。
// 中断处理器只需关句柄，python 及其孙进程（模型代码 subprocess 拉起的命令）一并终止——
// 靠控制台事件杀孙进程不可靠：ping 收到 CTRL_BREAK 只打印统计然后继续跑。
// 仅 runtime.c3 在 Windows 分支调用（$if env::WIN32）；本模块声明跨平台无害，
// POSIX 上是不被引用的死代码。

// ---- 常量 ----

const uint JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE = 0x2000;
const int JOB_OBJECT_EXTENDED_LIMIT_INFORMATION = 9;

// ---- 类型 ----

// x64 布局，与 winnt.h 一致。
struct JobBasicLimits
{
	long per_process_user_time_limit;
	long per_job_user_time_limit;
	uint limit_flags;
	usz min_working_set;
	usz max_working_set;
	uint active_process_limit;
	usz affinity;
	uint priority_class;
	uint scheduling_class;
}

struct IoCounters
{
	ulong read_operation_count;
	ulong write_operation_count;
	ulong other_operation_count;
	ulong read_transfer_count;
	ulong write_transfer_count;
	ulong other_transfer_count;
}

struct JobExtendedLimits
{
	JobBasicLimits basic;
	IoCounters io;
	usz process_memory_limit;
	usz job_memory_limit;
	usz peak_process_memory_used;
	usz peak_job_memory_used;
}

// ---- 公开接口 ----

// 建 job（KILL_ON_JOB_CLOSE）并把进程挂进去。任一环节失败返回 null——
// 调用方退化为只杀直接子进程。失败多因宿主环境已有不兼容的 job（老系统不支持嵌套）。
// ponytail: 赋值发生在 spawn 之后，子进程若在被挂入前就拉起了孙进程，那个孙进程不在
// job 里、中断时不会被杀；窗口极短，实际难触发，要根除得改 CreateProcess 的挂起标志。
fn void* create_and_assign(void* process_handle)
{
	void* job = create_job_object_w(null, null);
	if (!job) return null;

	JobExtendedLimits info = {};
	info.basic.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
	if (!set_information_job_object(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, &info,
	                                (uint)JobExtendedLimits::size))
	{
		(void)terminate(job);
		return null;
	}
	if (!assign_process_to_job_object(job, process_handle))
	{
		(void)terminate(job);
		return null;
	}
	return job;
}

// 关掉 job 句柄：KILL_ON_JOB_CLOSE 使 job 内所有进程（含孙进程）一并终止。
extern fn int terminate(void* job) @cname("CloseHandle");

// ---- kernel32（@private） ----

extern fn void* create_job_object_w(void* attrs, void* name) @private @cname("CreateJobObjectW");
extern fn int set_information_job_object(void* job, int cls, JobExtendedLimits* info, uint len) @private @cname("SetInformationJobObject");
extern fn int assign_process_to_job_object(void* job, void* process) @private @cname("AssignProcessToJobObject");
