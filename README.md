# 家庭升学信息研究库

帮助一个家庭在证据基础上理解本科升学选项：比较全国高校面向**辽宁考生**的招生与培养信息，逐步形成可核对、符合孩子与家长意愿的候选方案。

**这不是**志愿填报软件，**不是**以抓取数量为 KPI 的数据工程，**也不**承诺录取或就业结果。正式报考由家庭通过官方渠道自行完成。

## 研究边界（当前依据）

| 维度 | 当前设定 | 说明 |
| --- | --- | --- |
| 生源省 | 辽宁 | 指招生规则与录取数据口径，不是“只报辽宁高校” |
| 高校范围 | 全国 | 家庭是否接受某城市尚未确认，不能默认全部可接受 |
| 选科 | 物理、化学、生物 | 只证明组合；具体专业仍以报考年度要求为准 |
| 高考年份 | 暂记 2028 | 来自家长描述的升学时间，不随 session 日期自动改 |
| 成绩定位 | 校内排名等已登记 | 无可靠省位次时，不做冲稳保或录取概率 |
| 专业/地域/预算 | 未确认 | 研究保持中立，不把未知当成已拒绝 |

家庭事实与反馈见 `private/profile.csv`（不进入公开分享）；详细条件表见 [PLAN.md](PLAN.md) 第 1 节。

## 文档地图

| 文件 | 用途 |
| --- | --- |
| [README.md](README.md) | 本介绍与入口索引 |
| [AGENTS.md](AGENTS.md) | Agent 接续规则与编码守则（自动化助手必读） |
| [PLAN.md](PLAN.md) | 分阶段目标、任务 ID、产物与验收（稳定，不逐 session 改状态） |
| [STATUS.md](STATUS.md) | 当前进度、阻塞、下一任务与 session 交接（实时索引） |
| [RESEARCH.md](RESEARCH.md) | 初始调研思路与来源层级（背景，不代替最新进度） |
| [data/README.md](data/README.md) | 六表 CSV 结构、工具命令、隐私与备份 |
| [MAJORS_AND_PATHWAYS.md](MAJORS_AND_PATHWAYS.md) | 专业比较与升学渠道梳理 |
| [SUBJECT_REQUIREMENTS.md](SUBJECT_REQUIREMENTS.md) | 辽宁物化生选科匹配派生结果 |

数据与原件：`data/*.csv`、`raw/manifest.jsonl` 及 `data/derived/` 下派生清单；招生事实与口径说明见 [data/ADMISSION_BASE.md](data/ADMISSION_BASE.md)。

## 如何接续工作

1. 读 [STATUS.md](STATUS.md) 中的**下一任务**与阻塞项。
2. 读 [PLAN.md](PLAN.md) 对应 phase 的验收标准。
3. 核对实际 CSV、原件哈希与来源 ID，勿凭旧聊天或快照计数当永久事实。
4. 完成一个可核实产物后，更新 STATUS（任务状态、验证、下一步）。

自动化助手另须遵守 [AGENTS.md](AGENTS.md)。常用校验：`ruby scripts/research_data.rb check`；本地备份：`ruby scripts/research_data.rb backup`（详见 PLAN 与 `data/README.md`）。

## 原则摘要

- **分开**官方事实、分析推断、假设、未知与家庭决定。
- **不混用**学校投档、专业投档、最终录取、计划人数等不同统计类型。
- **保留**原件、来源、年份、口径与派生方法；纠错留痕，不覆盖用户已确认内容。
- **不做**代登录、绕访问限制、索取密码或考生号、自动填志愿或云上传。

## 许可与隐私

本库含家庭私有字段（`private/`）。请勿将私有内容或凭据提交到公开仓库或第三方服务。公开证据以 `data/sources.csv` 登记为准。
