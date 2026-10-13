package main

import win "core:sys/windows"

// ---- 分节 ----
// Job Object 封装：把子进程挂进“句柄关闭即杀全家”（KILL_ON_JOB_CLOSE）的 job。
// 中断/看门狗只需关句柄，bash 及其孙进程一并终止——靠控制台事件杀孙进程不可靠。
// 仅 runtime 在 Windows 分支调用；本模块声明跨平台无害（非 Windows 为空实现）。
// core:sys/windows 未导出 Job Object API，这里自声明 kernel32 外部函数。

JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE :: 0x2000
JOB_OBJECT_EXTENDED_LIMIT_INFORMATION :: 9

when ODIN_OS == .Windows {
	foreign import kernel32 "system:Kernel32.lib"

	@(default_calling_convention = "system")
	foreign kernel32 {
		@(link_name = "CreateJobObjectW")
		create_job_object_w :: proc(attrs: rawptr, name: cstring16) -> win.HANDLE ---
		@(link_name = "SetInformationJobObject")
		set_information_job_object :: proc(job: win.HANDLE, cls: u32, info: rawptr, len: u32) -> win.BOOL ---
		@(link_name = "AssignProcessToJobObject")
		assign_process_to_job_object :: proc(job: win.HANDLE, process: win.HANDLE) -> win.BOOL ---
	}
}

// x64 布局，与 winnt.h 一致。
JobBasicLimits :: struct {
	per_process_user_time_limit: i64,
	per_job_user_time_limit:     i64,
	limit_flags:                 u32,
	min_working_set:             uintptr,
	max_working_set:             uintptr,
	active_process_limit:        u32,
	affinity:                    uintptr,
	priority_class:              u32,
	scheduling_class:            u32,
}

IoCounters :: struct {
	read_operation_count:  u64,
	write_operation_count: u64,
	other_operation_count: u64,
	read_transfer_count:   u64,
	write_transfer_count:  u64,
	other_transfer_count:  u64,
}

JobExtendedLimits :: struct {
	basic:                    JobBasicLimits,
	io:                       IoCounters,
	process_memory_limit:     uintptr,
	job_memory_limit:         uintptr,
	peak_process_memory_used: uintptr,
	peak_job_memory_used:     uintptr,
}

// 建 job（KILL_ON_JOB_CLOSE）并把进程挂进去。任一环节失败返回 nil——
// 调用方退化为只杀直接子进程。
winjob_create_and_assign :: proc(process_handle: uintptr) -> rawptr {
	when ODIN_OS == .Windows {
		job := create_job_object_w(nil, nil)
		if job == nil {
			return nil
		}
		info: JobExtendedLimits
		info.basic.limit_flags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
		if !set_information_job_object(job, JOB_OBJECT_EXTENDED_LIMIT_INFORMATION, &info,
		                               u32(size_of(JobExtendedLimits))) {
			win.CloseHandle(job)
			return nil
		}
		if !assign_process_to_job_object(job, win.HANDLE(process_handle)) {
			win.CloseHandle(job)
			return nil
		}
		return rawptr(job)
	} else {
		return nil
	}
}

// 关掉 job 句柄：KILL_ON_JOB_CLOSE 使 job 内所有进程（含孙进程）一并终止。
winjob_terminate :: proc(job: rawptr) {
	when ODIN_OS == .Windows {
		if job != nil {
			win.CloseHandle(win.HANDLE(job))
		}
	}
}
