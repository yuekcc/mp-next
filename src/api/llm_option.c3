// llm_option — api 模块的接口设置数据形态（LlmOption）与内置传输/重试 DEFAULT_*
// 常量。模块无状态、零环境变量访问：字段由调用方按自身配置来源组装
// （default_options() 起步），本模块只消费。
module api;

// 内置传输/重试策略（一般无需修改；改默认值即改行为）
const String DEFAULT_URL = "https://api.openai.com/v1/chat/completions";
const int DEFAULT_CONNECT_TIMEOUT = 10; // 建连超时秒（0 = 关闭）
const int DEFAULT_MAX_TIME = 600; // 单次 HTTP 尝试硬上限秒（0 = 关闭）
const int DEFAULT_SPEED_LIMIT = 100; // 低速中止下限 bytes/s（与 speed_time 同为 0 才关闭）
const int DEFAULT_SPEED_TIME = 60; // 持续低于限速秒数
const int DEFAULT_RETRIES = 2; // 瞬时失败重试次数（0 = 关闭，即最多 1 次尝试）
const int DEFAULT_BACKOFF = 1; // 退避基数秒（第 n 次等待 backoff * n 秒）

// 调用方显式传入的接口设置。模块只消费字段、不感知其来源；url 为空则传输层无有效
// 端点（行为等同调用方配置错误），调用方可经 default_options() 起步获得 DEFAULT_URL。
struct LlmOption
{
	String url; // chat-completions 端点
	String api_key; // Bearer token；空则不发送 Authorization 头（本地服务场景）
	String extra_body; // 原样 JSON 对象字符串；序列化时解析合并进请求体（同名覆盖）
	bool debug; // 打印请求体到 stderr 等诊断（stdout 不受影响）
	String provider_label; // provider 台账标签（CLI 写 ledger 用；模块自身不消费）
}

// 纯默认构造（不读任何环境/文件）：url 预填模块默认端点，其余为零值。
// 调用方基于返回值按自身配置来源覆盖字段。
fn LlmOption default_options()
{
	LlmOption c;
	c.url = DEFAULT_URL;
	return c;
}
