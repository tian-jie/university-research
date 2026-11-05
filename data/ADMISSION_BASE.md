# 全国高校面向辽宁考生的投档底表

更新日期：2026-11-05。高校范围全国，生源省辽宁；当前整理普通类本科批物理学科类，未纳入提前批、征集志愿、历史学科类或专科投档表。

## 已完成

| 数据 | 年份 | 本次新增记录 | 院校编号＋名称组数 | 状态 |
| --- | --- | ---: | ---: | --- |
| 专业投档最低分及七项同分排序 | 2024 | 10,624 | 917 | 全表解析，并用原始XLSX XML逐行核对 |
| 专业投档最低分及七项同分排序 | 2026 | 11,628 | 956 | 全表解析，并用原始XLSX XML逐行核对 |
| 省级本科物理投档附件 | 2025 | 未入库 | 未知 | 官方附件为加密Excel包，已归档但未解密或读取 |

两年合计22,252条专业投档记录；与此前17条学校官方录取样本分别保存在[admissions.csv](admissions.csv)，总计22,269条。917和956是分别按年统计的编号＋名称组合，不是两年不重复学校数，也不是可报考名单或招生人数。

2025年缺的是省级完整投档底表；此前已核实的西交大2025年11条学校查询样本仍保留，不能以它们代替全省底表。

原表七项同分排序为：语数成绩、语数最高成绩、外语成绩、首选科目成绩、再选科目最高成绩、再选科目次高成绩、志愿号。原院校编号、专业编号、完整名称、工作表与行号保留在[投档派生清单](derived/admission-transfers/manifest.jsonl)登记的文件中，不把招生大类拆成保证可进入的独立专业。

“普通类”是此表的招生大类，不意味着每条都是无中外合作、无定向、无其他限制的常规项目。历史投档记录也不确认2028年仍招生，未取得的选科、校区、计划人数及其他资格字段留空。

## 位次区间

已读取三年物理学科类成绩统计PDF，每年4页：

| 年份 | 原表分数段行数 | 另行推导的零人数段 | 输出合计 |
| --- | ---: | ---: | ---: |
| 2024 | 559 | 0 | 559 |
| 2025 | 556 | 2 | 558 |
| 2026 | 558 | 1 | 559 |

零人数段只在相邻已读行的累计差能证实缺失分数段人数为零时补入，使用`inferred_zero_gap=true`明确区分，页码和位次区间留空；它们不是官方原表行。未知标签、累计异常或无法确认的缺口会报错，不静默补数。

单分段的参考区间起点为“累计人数－本分人数＋1”，终点为累计人数。最高分合并段保留原标签和合并范围，不解释成某个具体分数的同分人数。零人数段不能产生考生位次。

**三年原表脚注均说明：成绩为文化课总分与政策加分之和，人数为普通类、艺术类和体育类人数之和。**所以不能把这些结果称为纯普通类排名；投档计分口径仍需进一步官方确认。这里只建立同年分数映射参考，不宣称官方发布的专业最低位次。

2024和2026的22,252条投档记录均匹配到同年有考生的单分段，未匹配0条。但匹配成功只表示数值能关联，不等于计分口径已完全一致，更不表示孩子可以录取。

最新结果：[分数段与位次清单](derived/score-distributions/score-distributions-20261104T234430Z-57689/score-bands.csv)、[专业投档分数映射参考](derived/score-distributions/score-distributions-20261104T234430Z-57689/admission-rank-reference.csv)、[范围与脚注摘要](derived/score-distributions/score-distributions-20261104T234430Z-57689/summary.json)。后续运行生成新快照，历次输出见[清单](derived/score-distributions/manifest.jsonl)。

`admissions.csv`中的`rank`仍留空，避免把同分区间终点伪装成精确专业最低位次。

## 复现与校验

Ruby解析Excel，Node及固定版pdfjs-dist解析PDF；依赖不是另一个填报应用。Ruby依赖见[Gemfile](../Gemfile)，PDF依赖见[package.json](../scripts/pdfjs/package.json)及[锁文件](../scripts/pdfjs/package-lock.json)。在项目根目录：

```sh
bundle install
npm ci --prefix scripts/pdfjs --ignore-scripts --no-audit --no-fund
ruby scripts/admission_transfers_test.rb
ruby scripts/score_distributions_test.rb
ruby scripts/admission_transfers.rb 2024 2026
ruby scripts/score_distributions.rb run
ruby scripts/research_data.rb check
ruby scripts/score_distributions.rb check
```

如本机终端的PATH未含Homebrew工具目录，可用`PATH="/opt/homebrew/bin:$PATH" /opt/homebrew/bin/npm ci --prefix scripts/pdfjs --ignore-scripts --no-audit --no-fund`。PDF脚本会查找已有Node，不会自动安装系统工具。

不带年份参数的投档导入会尝试包含2025年，当前因此显式报加密附件不可读；可用上面的已验证年份组合。相同原表跨天重跑不重复写入，真实分数等字段发生冲突仍拒绝。

基本`check`检查六表、原件和选科派生数据；分数段专用`check`另外检查已登记快照哈希、来源、累计和最新位次关联。2024、2026投档原始XML的逐行核对在投档测试中执行，不因基本检查通过就声称所有研究结论成立。

## 下一步

优先补2025年可读的公开官方投档原件，并补逐年招生计划与选科要求。随后结合费用、校区、培养分流和专业内容形成全国高校候选池；计划调整或征集剩余人数不能替代首次完整计划。

目前不根据校内排名计算省位次，不划分个体冲稳保，不预测2028年的分数或录取概率。