package main

import "core:testing"

// ---- S3：agent.extract_code（纯函数，bash + heredoc 感知） ----

@(test)
extract_code_returns_false_without_fence :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := extract_code("just prose, no code here")
	testing.expect(t, !res.has_code)
	testing.expect_value(t, res.code, "")
}

@(test)
extract_code_basic_bash_block :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := extract_code("计划如下。\n```bash\nls -la\n```\n")
	testing.expect(t, res.has_code)
	testing.expect_value(t, res.code, "ls -la\n")
	testing.expect(t, !res.truncated)
}

@(test)
extract_code_bare_fence :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := extract_code("```\necho hi\n```\n")
	testing.expect(t, res.has_code)
	testing.expect_value(t, res.code, "echo hi\n")
}

@(test)
extract_code_fence_at_prose_line_end :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := extract_code("先看看。```bash\nls\n```\n")
	testing.expect(t, res.has_code)
	testing.expect_value(t, res.code, "ls\n")
}

@(test)
extract_code_marks_truncated_when_more_blocks_follow :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := extract_code("```bash\nfirst\n```\ntext\n```bash\nsecond\n```\n")
	testing.expect(t, res.has_code)
	testing.expect_value(t, res.code, "first\n")
	testing.expect(t, res.truncated)
}

@(test)
extract_code_empty_block_still_has_code :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := extract_code("```bash\n```\n")
	testing.expect(t, res.has_code)
	testing.expect_value(t, res.code, "")
}

@(test)
extract_code_inner_fence_line_does_not_close :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := extract_code("```bash\necho ```python\necho done\n```\n")
	testing.expect(t, res.has_code)
	testing.expect_value(t, res.code, "echo ```python\necho done\n")
}

@(test)
extract_code_heredoc_swallows_closing_fence :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := extract_code("```bash\ncat <<EOF\n```\nstill heredoc\nEOF\necho after\n```\n")
	testing.expect(t, res.has_code)
	testing.expect_value(t, res.code, "cat <<EOF\n```\nstill heredoc\nEOF\necho after\n")
}

@(test)
extract_code_trims_trailing_blank_lines :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	res := extract_code("```bash\nls\n\n\n```\n")
	testing.expect(t, res.has_code)
	testing.expect_value(t, res.code, "ls\n")
}

// ---- slug_from：目录名/日志里的 traj 名不能含半个多字节字符 ----

@(test)
slug_from_does_not_split_multibyte_char :: proc(t: ^testing.T) {
	defer free_all(context.temp_allocator)
	// 前 10 个字 30 字节，"个" 占第 31..33 字节；32 字节上限应回退到 30。
	testing.expect_value(t, slug_from("统计当前目录下有多少个文件"), "统计当前目录下有多少")
}
