<!-- 提交 PR 时请保留以下结构，删除不适用的小节 -->

## 改动类型

- [ ] Bug 修复
- [ ] 新功能 / 参数
- [ ] 文档
- [ ] 测试 / CI
- [ ] 其它：

## 这个改动解决什么问题

<!-- 描述现象与根因。若来自 Issue，请写 #编号 -->

## 我实测过的证据

<!-- 必填：贴命令与真实输出（不要写"应该没问题"） -->

```powershell
# 例如：
# .\tests\Test-GameBoost.ps1
```

```
（粘贴关键输出：PASS/FAIL 统计、冻结/恢复耗时、journal 片段等）
```

## 自检清单

- [ ] 本地跑通 `.\tests\Test-GameBoost.ps1`（退出码 0）
- [ ] `Invoke-ScriptAnalyzer -Path . -Recurse -Severity Error` 无 Error 级问题
- [ ] 新增/修改的 `.ps1`、`.json` 均为 **UTF-8 with BOM**
- [ ] 未引入第三方依赖或编译步骤（保持纯 PowerShell）
- [ ] 未放宽安全红线（反作弊/杀毒保护、会话 0 排除、指纹校验）
- [ ] 行为变更已同步 README（中英双份）与 CHANGELOG
- [ ] 未改动版本号 / LICENSE / social-preview.png

## 环境

<details><summary>环境信息</summary>

- Windows：
- PowerShell：
- 是否管理员：
- 复现用的目标进程：

</details>
