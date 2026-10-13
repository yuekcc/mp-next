package main

import "core:fmt"

// ---- 分节 ----
// llmcli（Odin 重写）入口。当前是最小脚手架：只保证 odin build / odin test 可跑；
// 子命令派发与 run 编排见后续阶段（todo：tmp/odin-port-todo.md）。

main :: proc() {
	fmt.println("llmcli (odin scaffold)")
}
