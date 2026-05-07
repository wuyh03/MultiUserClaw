  先纠正一下实际链路：当前聊天前端不是 WebSocket，而是 POST /messages 发消息 + SSE /events/stream 收流。frontend/src/pages/Chat.tsx:561
  platform/app/routes/proxy.py:328

  最主要的慢点

  1. 前端自己做了打字机限速，硬性限制到大约 150 chars/sec。代码里每 20ms 只放 3 个字符，1500 字回答光前端动画就要 10 秒左右。frontend/src/pages/
     Chat.tsx:101
  2. 前端在收到 final 后又故意多等 3s，收到 lifecycle end 后又等 1s，然后才拉最终消息，所以“回答已经结束了但 UI 还在转”。frontend/src/pages/
     Chat.tsx:476 frontend/src/pages/Chat.tsx:536
  3. 网关发给前端的 delta 不是增量，而是“截至当前的整段全文”；同时还做了 150ms 节流。openclaw/src/gateway/server-chat.ts:724 这会带来两个问题：
      - 长回复时 payload 越来越大
      - 前端每次都在重设整段文本，再配合打字机，体感更慢
  4. 前端每个 SSE chunk 都 console.log，流式回复时日志很多，浏览器 DevTools 打开时会明显拖慢。frontend/src/pages/Chat.tsx:450 frontend/src/
     pages/Chat.tsx:579

  后端/模型侧还能再抠的延迟

  1. platform 的 LLM proxy 每次请求前都要做鉴权、查用户/容器、再跑一次“今天已用 token 求和”。这是真实首包延迟来源之一，尤其并发高时更明显。
     platform/app/llm_proxy/service.py:265 platform/app/llm_proxy/service.py:194
  2. usage_records 目前只有 user_id 单列索引，没有 (user_id, created_at) 这种适合 quota 查询的组合索引；数据多了以后 _check_quota() 会越来越贵。
     platform/app/db/models.py:90
  3. 聊天默认可能会自动带上 thinking/reasoning，这会真实增加模型首 token 延迟。这个要看你当前会话和默认模型配置。openclaw/src/gateway/server-
     methods/chat.ts:1297 openclaw/src/agents/model-selection.ts:778
  4. SSE 双代理本身看起来只是透明转发，不像主要瓶颈。openclaw/bridge/routes/events.ts:12 platform/app/routes/proxy.py:350

  建议按这个顺序改

  1. 去掉前端打字机，直接显示流式文本。
  2. 去掉 final 的 3 秒和 lifecycle end 的 1 秒 debounce，收到终态立即收尾。
  3. 删掉 SSE per-chunk console.log。
  4. gateway 改成发送真正的 delta，前端本地 append；同时把 150ms 节流降到 30-50ms，或者按字符数自适应。
  5. platform 给 quota 查询加组合索引 (user_id, created_at)，并把“今日用量”改成缓存/聚合计数，而不是每次 sum()。
  6. 如果当前默认 thinking 不是 off/low，聊天场景降一级。

  如果只改前 3 项，体感通常会立刻快很多；如果再加第 4 项，长回答会明显顺滑；第 5、6 项主要改善首包时间和高并发下稳定性。



  🎯 优化设计方案

  阶段 1：前端即时展示 + 去掉 Debounce

  改动点：
  - frontend/src/pages/Chat.tsx：删除 setStreamingText 的打字机逻辑，改成直接设置文本
  - 删除 final 的 3s debounce 和 lifecycle end 的 1s debounce → 收到 final 立即调用 getSession
  - 删除所有 console.log（除了错误日志）

  效果： 同一条消息从"等 10 秒看打字"变成"1-2 秒展示完"

  ---
  阶段 2：Bridge SSE Delta 格式 + 固定 50ms 节流

  改动点：
  - openclaw/bridge/routes/events.ts：改 SSE 消息格式
    - 原：{state: 'delta', message: {content: [完整文本]}}
    - 新：{state: 'delta', message: {content: [{type: 'text', text: '增量部分', is_delta: true}]}, ...}
  - 节流从 150ms → 50ms

  前端适配：
  - frontend/src/pages/Chat.tsx：识别 is_delta 字段，改为 append 而非重设整段文本

  效果： 长回复不再"一整段重新渲染"，payload 逐渐变小

  ---
  阶段 3：Platform Quota 内存缓存 + TTL

  改动点：
  - platform/app/llm_proxy/service.py：新增 QuotaCache 类（内存 + TTL）
  - 改 _check_quota() 首先查缓存，缓存未命中才 sum()，然后缓存 30-60s

  DB 优化（可选但建议）：
  - 给 usage_records 表加组合索引 (user_id, created_at DESC)

  效果： 首包延迟 ↓ 200-500ms，高并发时稳定性 ↑

  ---
  阶段 4：验证脚本

  用 Python/Node 写自动化测试脚本，测量：
  - 消息首字出现时间
  - 完整回复显示时间
  - SSE 流的 p99 延迟
  - Quota 查询耗时

  ---
  ❓ 这个设计是否对应所有优化点？

  ✅ 前端打字机 → 阶段 1
  ✅ Debounce → 阶段 1
  ✅ Console.log → 阶段 1
  ✅ 真正 Delta + 节流 → 阶段 2
  ✅ Quota 缓存 → 阶段 3
  ⚠️  Thinking 配置 → 暂不改（需要确认当前默认值）

  看起来没问题吗？需要调整吗？


# 启动速度优化
已删除 qmd： bridge-entrypoint.sh 中移除了 qmd collection add / qmd update 和 qmd-runner.sh 同步相关代码。
已添加启动优化环境变量到 Dockerfile.bridge：
环境变量
OPENCLAW_SKIP_PROVIDERS=1
OPENCLAW_SKIP_CRON=1
OPENCLAW_LOAD_SHELL_ENV=0
OPENCLAW_SKIP_BROWSER_CONTROL_SERVER=1
这些变量能让 gateway 子进程的启动省掉若干阻塞操作。另外注意到 CMD 用的 node --import tsx bridge/start.ts 会在运行时用 tsx 重新编译 bridge 的 TypeScript，但 bridge 编译产物（bridge/dist/）已经存在。可以把 CMD 改成直接用编译后的 JS：
CMD ["node", "bridge/dist/bridge/start.js"]


# platform下的速度优化
⏺ 分析完成。以下是 platform 中发现的性能瓶颈，按影响程度分类：

  ---
  高影响（建议优先处理）

  ┌─────┬────────────────────────────────────┬────────────────────────────────────┬─────────────────────────────────────────────────────────┐
  │  #  │                问题                │                位置                │                          现象                           │
  ├─────┼────────────────────────────────────┼────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 1   │ Docker SDK                         │ container/manager.py 全文件        │ 容器创建/管理时整个 asyncio                             │
  │     │ 全是同步调用，阻塞事件循环         │                                    │ 事件循环被阻塞，期间无法处理其他请求                    │
  ├─────┼────────────────────────────────────┼────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 2   │ 每个请求创建新的 httpx 连接池      │ proxy.py:56/406/496,               │ 每次代理请求都新建 TCP 连接，无连接复用，增加延迟       │
  │     │                                    │ shared_runtime.py:59               │                                                         │
  ├─────┼────────────────────────────────────┼────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 3   │ get_user_by_id 无缓存 —            │ auth/dependencies.py:14-26         │ 高频端点每次都重新查询用户表。建议加 30s TTL            │
  │     │ 每个认证请求都查 DB                │                                    │ 内存缓存（与 QuotaCache 同理）                          │
  ├─────┼────────────────────────────────────┼────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 4   │ SSE 流期间持有 DB 会话不释放       │ llm_proxy/service.py:288-446       │ LLM 流式响应可能持续数分钟，期间占用一个 DB             │
  │     │                                    │                                    │ 连接。多用户并发时连接池易耗尽                          │
  ├─────┼────────────────────────────────────┼────────────────────────────────────┼─────────────────────────────────────────────────────────┤
  │ 5   │ upsert_chat_session 已优化 ✅      │ 刚才已完成                         │ 已改为 fire-and-forget，不阻塞聊天                      │
  └─────┴────────────────────────────────────┴────────────────────────────────────┴─────────────────────────────────────────────────────────┘

  ---
  中影响

  ┌─────┬───────────────────────────────┬────────────────────────────────┬─────────────────────────────────────────────────────────────────┐
  │  #  │             问题              │              位置              │                              建议                               │
  ├─────┼───────────────────────────────┼────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
  │ 6   │ 注册时串行检查用户名+邮箱     │ routes/auth.py:74-77           │ 改用 asyncio.gather 并行查询                                    │
  ├─────┼───────────────────────────────┼────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
  │ 7   │ LLM 代理认证串行查询          │ llm_proxy/service.py:315-330   │ 容器查询和用户查询可并行                                        │
  ├─────┼───────────────────────────────┼────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
  │ 8   │ 缺少 DB 索引                  │ models.py                      │ usage_records.created_at、audit_logs.(action,                   │
  │     │                               │                                │ created_at)、containers.status、containers.docker_id            │
  ├─────┼───────────────────────────────┼────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
  │ 9   │ 同步 bcrypt 阻塞登录路径      │ auth/service.py:18-23          │ verify_password 耗时 100-300ms，用 asyncio.to_thread 包裹       │
  ├─────┼───────────────────────────────┼────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
  │ 10  │ Container + AgentBinding      │ container/manager.py,          │ 聊天热路径上反复查询，加 5-10s 缓存                             │
  │     │ 无缓存                        │ shared_runtime.py              │                                                                 │
  ├─────┼───────────────────────────────┼────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
  │ 11  │ sync_all_container_statuses   │ routes/admin.py:259-292        │ 批量处理 Docker 状态同步                                        │
  │     │ N+1 查询                      │                                │                                                                 │
  ├─────┼───────────────────────────────┼────────────────────────────────┼─────────────────────────────────────────────────────────────────┤
  │ 12  │ pool_pre_ping=True 每次检出都 │ db/engine.py:7-15              │ 每个 DB 会话获取都额外一次往返                                  │
  │     │  ping                         │                                │                                                                 │
  └─────┴───────────────────────────────┴────────────────────────────────┴─────────────────────────────────────────────────────────────────┘

  ---
  低影响

  - LLM 用量记录在 finally 中同步写入 → 可改为后台任务
  - 用量历史查询中两个聚合查询串行 → asyncio.gather
  - SSE filter 每次 JSON 解析 → 可用字符串前缀匹配代替
  - Root logger 设为 DEBUG → 无用日志消耗 CPU

  ---
  建议优先做 4 件事，改动小、收益大：

  1. httpx 连接池复用 — 创建一个模块级共享 httpx.AsyncClient，避免每次请求重建连接
  2. get_user_by_id 缓存 — 参照已有 QuotaCache 模式，加 30s TTL
  3. SSE 流中 DB 写入后台化 — 用 create_task 把 UsageRecord 写入解耦（类似刚才做的 schedule_chat_session_upsert）
  4. 补缺失的 DB 索引 — 纯 DDL，零代码改动
