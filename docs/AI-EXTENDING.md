# 让 AI 帮你扩展 GameBoost / Extending GameBoost with AI

这份手册给两类人：**想用 AI 改造本项目的人**，和**正在执行改造的 AI 代理**。
它把"5 个高频任务"写成可直接复制的提示词，并列出每个任务的**不可变不变量**与**验证方式**。

> 先读 [`AGENTS.md`](../AGENTS.md)（红线 + 约定）。规则细节见 [`TECHNICAL.md`](TECHNICAL.md) §6/§7，
> 机器可读版本见 [`llms.txt`](llms.txt) 与 [`llms-full.txt`](llms-full.txt)。

---

## 0. 给 AI 的"通用开工提示词"（复制即用）

```
你在维护 GameBoost（Windows 后台进程冻结工具，纯 PowerShell 5.1 + WinForms，零依赖）。
先读 AGENTS.md 与 docs/AI-EXTENDING.md，再动手。

任务：<在这里写你要改什么>

硬性要求：
1. 不得放宽任何硬保护（反作弊/杀毒/系统关键/会话 0/自身进程链/前台全屏）——配置、规则表、显式名单都不能解除。
2. 所有 .ps1 / .json 必须 UTF-8 with BOM；PowerShell 5.1 兼容；Add-Type 用 C# 5 语法。
3. 不引入外部依赖；不写注册表/不停服务/不结束进程（冻结=挂起，不是 kill）。
4. 改动必须同步：pause/resume 两侧语义一致、-EmitJson 字段、schemas/、tests/ 断言、README/CHANGELOG。
5. 交付前必须给出验证证据：tests\Test-GameBoost.ps1 全绿 + GUI -SelfTest 退出码 0 + 相关枚举命令输出。
6. 不要在没有跑验证的情况下宣称完成。
```

---

## 任务 1：给某个软件加规则（最常见）

**场景**：某个下载器/厂商控制台/网盘在后台抢资源，希望游戏前自动处理它，但不希望写死成"必须冻结"。

**提示词要点**：给出进程名（任务管理器里的名字，不带 `.exe`）、期望动作、内存量级。

```json
// config.json → selectRules 里"小工具不处理"之前插入；或写成独立文件用 -RuleFile 加载
{ "name": "某下载器：只在后台占用大时冻结", "match": "某下载器进程名*", "action": "suspend", "minMemoryMB": 150 }
```

**不变量**：规则按顺序匹配、**首个命中生效**，所以通配 `"*"` 的兜底规则必须放在最后；
`match` 匹配的是进程名；门槛按**进程名聚合**（同名字所有进程工作集求和）。

**验证**：

```powershell
# 看规则判定（不改动任何进程）
.\pause-non-system-processes.ps1 -EmitJson -JsonOut .\state\scan.json -Scope Broad
# 只看那一条
(Get-Content .\state\scan.json -Raw -Encoding UTF8 | ConvertFrom-Json).processes |
  Where-Object name -eq '某下载器进程名' | Format-List name,wsMB,state,action,rule
```

期望：`action` 与 `rule` 就是你没有期望的那条规则名（`rule` 为空字符串 = 未命中任何规则 → 默认 `suspend`）。

---

## 任务 2：新建一套档案（场景化策略）

**场景**：笔记本省电 / 编译时不打扰 / 直播时保留聊天，各要一套策略。

**两种放置方式**：
- 想让 **GUI 下拉框**能选 → 写进 `config.json` 的 `profiles` 段（键名即显示名）
- 想自己留着/分享 → 独立文件，`-Profile .\profiles\xxx.json` 加载（模板见 `profiles/游戏前.json`）

```json
{
  "name": "编译时：保留编辑器与终端",
  "scope": "Safe",
  "mode": "Suspend",
  "minMemoryMB": 80,
  "exclude": ["code", "devenv", "pycharm64", "idea64", "WindowsTerminal", "powershell", "cmd"],
  "rules": [
    { "name": "浏览器大户冻结", "match": "chrome|msedge|firefox", "action": "suspend", "minMemoryMB": 300 },
    { "name": "聊天/同步走软模式", "match": "Weixin|QQ|OneDrive*", "action": "idle" },
    { "name": "其余后台冻结", "match": "*", "action": "suspend" }
  ]
}
```

**不变量**：`exclude` 是"永不自动冻结"，优先级高于规则表；`include` 用来把范围收窄（只处理这些名字）；
`minMemoryMB` 是档案级门槛（按名字聚合），低于它的名字直接 `skip`。

**验证**：

```powershell
.\pause-non-system-processes.ps1 -Profile '编译时' -DryRun      # 只打印计划与逐名字判定
.\pause-non-system-processes.ps1 -Profile .\profiles\xxx.json -DryRun
# 未知档案名会报错并列出可用档案——用它确认名字拼对了
```

---

## 任务 3：给规则表加一个新动作（例如 `throttle`）

**场景**：除了"真冻结 / 只降 QoS / 不处理"，还想要"限制但不能挂起"（例如只降内存优先级 + 清空工作集但不挂线程）。

**改动点（必须同时改 5 处，缺一不可）**：

| 位置 | 改什么 |
|---|---|
| `pause-non-system-processes.ps1` 4b 段 | 规则 `action` 的新取值如何落到本轮执行计划（`$script:ActionOf`） |
| `pause` 的执行段 / `$useIdle` | 新动作实际调用哪些 API（例如仅 `EmptyWorkingSet` + `SetProcessInformation`） |
| `resume-non-system-processes.ps1` | **恢复时怎么还原**（会话文件里要记哪些原值） |
| `-EmitJson` | 新 `action` 值要能被 GUI 与外部脚本看到 |
| `tests/Test-GameBoost.ps1` | 新增断言：动作生效 + 恢复后原值一致（用 `gbmemballoon` 合成进程） |

**不变量**：新动作同样**不能**作用在硬保护名单上；会话文件必须记录足够的还原信息（否则就是"不可逆操作"）；
新增动作不得改变既有 `suspend` / `idle` / `skip` 的语义。

**验证**：跑全量自测（新断言必须能证明"效果发生"且"恢复归位"），并用 `-EmitJson` 确认新 `action` 出现在清单里。

---

## 任务 4：扩展 `-EmitJson`，并让 GUI 显示

**场景**：想把"该名字下有多少进程来自会话 0"或"是否命中档案门槛"暴露给 GUI / 外部程序。

**步骤**：
1. 在 `pause` 的 EmitJson 段**追加**字段（不要改名或改语义）。
2. 更新 `schemas/scan.schema.json`（`required` + 属性定义）。
3. GUI 里消费它（例如状态列文案）——GUI **只读这份 JSON**，不要自己再算一遍。
4. `tests/Test-GameBoost.ps1` 增加断言：真扫描产物里该字段存在且类型正确。
5. `docs/llms-full.txt` §7 的契约示例同步。

**不变量**：`schema` 字段是**稳定契约**；追加字段是兼容变更，删除/改语义必须提升版本号。
GUI 不得因此产生"第二份名单"（会产生漂移）。

**验证**：

```powershell
.\pause-non-system-processes.ps1 -EmitJson -JsonOut .\state\scan.json -Scope Broad
# 顶层字段与 schema required 是否一致（自测 T12 会做这件事）
(Get-Content .\state\scan.json -Raw -Encoding UTF8 | ConvertFrom-Json) | Select-Object schema,profile,ruleCount
```

---

## 任务 5：GUI 加控件 / 改样式

**场景**：想加一个"只显示软模式项"的开关，或者换配色。

**要点**：
- 控件区在 `GameBoost.GUI.ps1` 顶部（主题 `$P` 调色板 + `New-Card` / `New-Button` / `New-Combo` / `New-Text` / `New-Check` 助手）。
- 视觉可以随意改，但**这些名字不能改**：`$lblStatus` `$cmbMode` `$cmbScope` `$chkAgent` `$chkVisible` `$chkAutoExe` `$txtAutoExe` `$chkAutoMin` `$numAutoMin` `$btnScan` `$btnApply` `$btnResume` `$btnStatus` `$btnOpen` `$lblSel` `$cmbProfile` `$btnAuto` `$txtFilter` `$btnResumeSel` `$lv` `$txtLog`——自检与 `-SelfTest` 报告依赖它们。
- `-SelfTest` 的 Note 文本（`SCAN rows=`、`GUI-FILTER`、`GUI-AUTOSEL`、`GUI-SELMEM`、`GUI-RESUME-SEL`、`protected-check guard`、`selected=…`）是自测断言的一部分，**不要删**；可以新增。
- 不要在 GUI 里实现保护判定：勾选与自动选择都基于 `-EmitJson` 的 `state` / `action`。

**验证**：

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File .\GameBoost.GUI.ps1 -SelfTest   # 退出码必须为 0
powershell -NoProfile -ExecutionPolicy Bypass -File .\tests\Test-GameBoost.ps1       # T8/T11 必须仍通过
```

---

## 可编程驱动（脚本 / AI 代理直接调用）

见 [`examples/agent-drive.ps1`](../examples/agent-drive.ps1)：`-EmitJson` → 按规则挑名字 → 写名单 → 打印命令；
**默认不动系统**，加 `-Execute` 才真正冻结，`-Resume` 只恢复这份名单里的名字。

```powershell
.\examples\agent-drive.ps1                     # 只看计划（安全）
.\examples\agent-drive.ps1 -Profile '游戏前'    # 按档案决策
.\examples\agent-drive.ps1 -Execute            # 真正冻结（等价于 GUI 的「暂停所选」）
.\examples\agent-drive.ps1 -Resume             # 只恢复上次这份名单
```

---

## 绝对不能做的事（违反即视为破坏项目）

1. 以任何方式放宽硬保护（反作弊 / 杀毒 / 系统关键 / 会话 0 / 自身进程链 / 前台全屏）。
2. 把冻结实现成 `Stop-Process` / `taskkill`（那是结束进程，不是冻结）。
3. 写注册表、停服务、改电源计划、注入、读写游戏内存、改杀毒设置。
4. 去掉或削弱指纹校验（`pid + 进程名 + 启动时间戳`）后做恢复。
5. 把本机信息写进仓库：主机名、用户名、`C:\Users\<name>\...`、代理端口、真实进程清单快照。
6. 让 GUI 自己实现一套判定逻辑（与 `-EmitJson` 并行维护两份名单）。
7. 在没跑 `tests\Test-GameBoost.ps1` 与 GUI `-SelfTest` 的情况下提交。
