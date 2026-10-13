# 参与贡献 / Contributing

感谢你有兴趣改进 GameBoost。这是一个**测试版**项目，真实反馈比代码贡献同样重要。

## 最重要的事：先跑一次，再报告

```powershell
# 1) 不改动任何东西，看它打算动谁
.\pause-non-system-processes.ps1 -DryRun

# 2) 跑自测套件（会短暂冻结一个自己启动的合成进程，不影响你的应用）
.\tests\Test-GameBoost.ps1
```

如果自测出现失败，**那就是最有价值的一类 Issue**：请附上完整的控制台输出。

## 报告问题（Issue）

请使用仓库的 Issue 模板，并尽量提供：

- 你执行的**确切命令**或界面操作
- `-DryRun` 的完整输出（能看出它选中了谁）
- `state\current.json`（可脱敏；这是本次冻结会话的指纹与原始状态记录）
- Windows 版本（`winver` 的 build 号）与 `$PSVersionTable.PSVersion`
- 是否以管理员运行

**最欢迎的三类报告**：

1. **误冻结**了不该冻的进程（尤其是导致游戏崩溃、反作弊报警、系统异常）
2. 该冻结的**没冻**（说明你的机器上有它没识别到的后台进程）
3. **恢复不完整**（残留挂起线程、QoS 没还原、进程异常）

## 提交代码（Pull Request）

- 保持 **纯 PowerShell + 零依赖**：不引入外部模块、不需要编译步骤
  （`Add-Type` 内嵌 C# 是可以的，但必须兼容 PS 5.1 的 C# 5 编译器：不能用 `$"..."`、表达式体成员、`nameof`）
- **所有 `.ps1` / `.json` 必须是 UTF-8 with BOM**（PS 5.1 会把无 BOM 的 UTF-8 中文按 ANSI 解析并报语法错误）
- 改动行为时，**同步更新 `README.md` / `README.zh-CN.md` 与 `CHANGELOG.md`**
- 提交前请本地跑通：

```powershell
# 语法与自测
.\tests\Test-GameBoost.ps1

# 可选：静态分析（CI 也会跑）
Install-Module PSScriptAnalyzer -Scope CurrentUser -Force
Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error
```

- PR 描述里请附上**你实测过的输出**（命令 + 结果）。CI 会跑 PSScriptAnalyzer 与自测套件，请确保通过。
- 不要在 PR 里改动 `docs/social-preview.png`、`LICENSE`、版本号（发版时由维护者统一处理）。

## 设计红线（请不要绕过）

以下约束是项目的安全底线，**不接受以"性能更好"为由的放宽**：

1. 反作弊（ACE / EasyAntiCheat / BattlEye / Vanguard 等）与杀毒进程**永不可被冻结**，且必须无法通过
   `config.json` 或命令行参数解除。
2. 默认不碰会话 0（服务）进程。
3. 只恢复本工具自己冻结过的进程（指纹校验不可移除）。
4. 不写注册表、不改服务、不改电源计划、不改杀毒设置、不联网。

## 行为准则

参与本项目即表示你同意遵守 [CODE_OF_CONDUCT.md](CODE_OF_CONDUCT.md)。
