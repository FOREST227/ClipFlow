# 条目详情盖板展开 Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task. Use checkbox tracking. 用户也可明确选择subagent-driven-development；本次未启动子代理。

**Goal:** 参考右侧适配视频，为历史页和快捷面板实现固定窗口内的分层展开/收回，保持滚动、命中及图片手势稳定。

**Architecture:** 原列表保持挂载，两个入口共用四阶段展示状态机和详情视觉层。粗粒度状态控制挂载/交互；独立进度对象只驱动动效。关闭完成前保留详情身份，修订号使旧更新和完成回调失效。

**Tech Stack:** Swift 6、SwiftUI、AppKit、Combine、XCTest；macOS 12+，无新依赖。

**Spec:** /Users/wuqicheng/Documents/AI 代码项目/剪切板/docs/superpowers/specs/2026-10-26-detail-expansion-animation-design.md

**Status:** 仅实施计划，尚未修改产品代码。基线e714289；用户确认本计划后再实施，不把提交设计文档当作动画已完成。

## Global Constraints

- “外部窗口尺寸和位置不变”；保持原列表六单位高度，不移动或搬走源行。
- “列表滚动位置、行身份和其他条目的排版保持不变”。
- “opening/open/closing全程阻止点击穿透，直到退出动画结束才恢复底层条目交互。”
- 设计要求“展开约260–300毫秒”“错峰约40–60毫秒”“关闭约180–220毫秒”；选定完整开280ms、关200ms、减弱动态110ms，正文约50ms开始重叠显现。
- 保留标题、来源时间、正文、复制/粘贴/置顶及更多信息，不新增重复摘要。
- 浅色正文纯白，深色/五类强调色不变。文字、WebKit和图片不随壳层压扁，不逐帧改变其布局。
- “关闭按钮、Esc、背景点击采用同一关闭路径”；不以鼠标移出关闭。
- 支持减少动态效果及减少透明度；60fps是待测目标。
- 不修改权限弹层动效、激活式NSPanel、外部粘贴目标和图片缩放实现。
- 不自动推送、打标签、发布或安装；实施时小步提交，整合由用户决定。

## Review Focus

1. 半途关闭/重开：旧回调不能清掉新详情，反向不跳变 → Task 1/2。
2. 底边半卡及下滚多屏：目标、原生身份、滚动位置保持 → Task 3/4。
3. 图片捏合与WebKit焦点：手势仍有效，Esc先关详情且不处理别的窗口按键 → Task 3/4。
4. 条目到期、删除、窗口失焦/销毁：无旧敏感内容、迟到粘贴 → Task 1/4。
5. 退出最后一帧与重复操作：不穿透、不误选、不重复粘贴 → Task 1/3/4。

## 文件边界

新增InspectorPresentation.swift负责状态与驱动协议；新增InspectorMotion.swift负责驱动及分层运动。ContentView.swift接入历史页/共用详情，Services.swift接入快捷面板/Esc。新增四个对应测试文件。以下路径均相对仓库根目录；所有命令在根目录运行，测试命令统一加DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer。

Models.swift、ClipboardRowHitView.swift、ZoomableDetailImage.swift原则上不改。DetailTextRenderer已有RenderKey缓存，保持其重复更新不重载的语义。

---

### Task 1: 可中断状态机

**Files:** Create Sources/ClipFlowApp/InspectorPresentation.swift；Test Tests/ClipFlowAppTests/InspectorPresentationTests.swift。
**Interfaces:**
- @MainActor InspectorAnimationDriving：animate(from: CGFloat, to: CGFloat, duration: TimeInterval, update: @escaping (CGFloat) -> Void, completion: @escaping () -> Void)；cancel()不调用completion。
- InspectorMotionProgress: ObservableObject：@Published private(set) var value: CGFloat，内部setValue(_:)；每帧通知不向控制器转发。
- InspectorPresentation: ObservableObject，init(driver: any InspectorAnimationDriving)；Phase=closed/opening/open/closing。@Published private(set) snapshot: Snapshot包含phase/itemID: UUID?/revision: UInt64；let motion: InspectorMotionProgress；var blocksBackground: Bool。
- open(itemID: UUID, reduceMotion: Bool)；dismiss(reduceMotion: Bool, afterClose: (() -> Void)? = nil)；reset()；invalidateIfMissing(availableIDs: Set<UUID>)。

- [ ] **1 RED测试：** FakeDriver手动emit/finish，无任意sleep。testClosingRetainsIdentity的核心断言：
  ~~~swift
  state.open(itemID: id, reduceMotion: false)
  driver.finishLatest()
  state.dismiss(reduceMotion: false)
  XCTAssertEqual(state.snapshot.itemID, id)
  XCTAssertTrue(state.blocksBackground)
  driver.finishLatest()
  XCTAssertNil(state.snapshot.itemID)
  XCTAssertFalse(state.blocksBackground)
  ~~~
  同文件：testReopenRejectsStaleCompletion断言新id保留；testReverseStartsAtDisplayedProgress从0.45反向；testDismissActionRunsOnce；testResetCancelsPendingPaste；testExpiredItemClearsImmediately；testUsesSpecDurations断言完整开0.28秒、关0.20秒、减弱动态0.11秒，从0.45关闭为0.09秒。
- [ ] **2 运行RED：** swift test --filter InspectorPresentationTests。Expected：新接口缺失，失败。
- [ ] **3 实现：** 只有closed不阻挡背景；关闭保留id至有效完成。重开/reset使旧update/completion及待执行动作失效。时长按剩余距离缩短；同条目已open重复请求无动作；重复dismiss不重复动作。过期/删除立即无动画清除，隐私优先。
- [ ] **4 运行GREEN：** 同一命令。Expected：0失败；多次进度emit不触发snapshot发布。
- [ ] **5 提交：** 只暂存上述两文件；git commit -m "feat: add interruptible inspector presentation lifecycle"。

### Task 2: 共用盖板与独立正文

**Files:** Create Sources/ClipFlowApp/InspectorMotion.swift；Modify Sources/ClipFlowApp/ContentView.swift中的LibraryInspectorOverlay；Test Tests/ClipFlowAppTests/InspectorMotionTests.swift。
**Interfaces:**
- Consumes Task 1协议。AppKitInspectorAnimationDriver实现协议，使用NSAnimation nonblocking/linear、请求60fps，主线程更新/完成；不用macOS 14限定的完成API。
- InspectorMotionValues.resolve(progress: CGFloat, reduceMotion: Bool, reduceTransparency: Bool) -> InspectorMotionValues；字段shellScaleY/shellOffsetY/contentOpacity/contentOffsetY/chromeOpacity/backdropProgress/backgroundBlur。
- InspectorMotionSurface<Content: View>，init(motion: InspectorMotionProgress, reduceMotion: Bool, reduceTransparency: Bool, content: @escaping (InspectorMotionValues) -> Content)。
- LibraryInspectorOverlay增加可选motion: InspectorMotionProgress? = nil；nil为完全展开，既有截图调用兼容。

- [ ] **1 RED测试：** testMotionEndpoints断言p=1的scaleY=1/offsetY=0/contentOpacity=1、p=0的正文opacity=0；testReducedMotion断言任意p不缩放/位移/模糊；testClampedFiniteProgress覆盖-1/2/0.5；testTicksPreserveRendererAndCanvasIdentity断言原生对象及RenderKey不变，同图不重新加载。
- [ ] **2 运行RED：** swift test --filter InspectorMotionTests。Expected：新接口缺失，失败。
- [ ] **3 实现：** 壳层从scaleY=0.90、下移16pt开始，quart-out；正文最多下移8pt，仅淡入/移动，标准线性进度约0.18至0.72显现。同一进度映射相同视觉值保证反向连续。背景blur最大1.4；backdropProgress为0…1，由历史/快捷入口分别乘0.18/0.16，避免共用解析器隐含窗口类型；减少透明度改不透明表面，不叠白雾。
- [ ] **4 分层与GREEN：** 壳层缩放只作用背景/裁剪，正文最终尺寸布局；操作区不增重复标题。只动效子树订阅进度。swift test --filter 'InspectorMotionTests|DetailTextRendererTests|ImagePinchTests|ImageViewportTests'；Expected：0失败、无重复WKWebView加载。
- [ ] **5 提交：** 只暂存本任务文件；git commit -m "feat: add layered inspector cover motion"。

### Task 3: 历史页接入

**Files:** Modify Sources/ClipFlowApp/ContentView.swift；Test Tests/ClipFlowAppTests/HistoryInspectorMotionTests.swift。
**Interfaces:** 消费Task 1/2；ContentView保留原参数并增加inspector: InspectorPresentation? = nil测试注入。右键open，关闭按钮/背景/Esc统一dismiss。用store.item(withID:)获取当前有效条目，不为退场缓存敏感全文。

- [ ] **1 RED测试：** testClosingKeepsNativeRowsDisabled：FakeDriver尚未完成时向保留行直接派发mouseDown也不选择；完成后恢复。testScrolledOpenClosePreservesRowsAndOffset：80条混排下滚两屏，每阶段行身份/偏移不变，进度tick不增加contentRevision。
- [ ] **2 运行RED：** swift test --filter HistoryInspectorMotionTests。Expected：缺少注入/关闭保护，失败。
- [ ] **3 接入：** 替换即时nil逻辑，详情mounted/blocking/opacity分开；权限弹层保持旧逻辑。右键先store.select(item)。背景直到closed才可操作；不引入hover打开/单击复制。过期/删除立即清除可读内容。
- [ ] **4 补测并GREEN：** testEscapeWithWebFocusClosesInspectorNotWindow；testWrongWindowEscapeIsIgnored；testPortraitAndShortTextFitWindow；testInvalidatedSensitiveItemDisappearsImmediately。swift test --filter 'HistoryInspectorMotionTests|HistorySelectionPerformanceTests|RowInteractionTests|StaleRowTargetTests|LibraryCardLayoutTests'；Expected：0失败、偏移误差≤1pt、无误选、主窗口不被Esc关闭；长图仍用现有DetailImageLayout。
- [ ] **5 提交：** 只暂存本任务文件；git commit -m "feat: integrate cover transition in history inspector"。

### Task 4: 快捷面板、Esc与实机验收

**Files:** Modify Sources/ClipFlowApp/Services.swift中的QuickPastePanelController/QuickPastePanel/QuickPastePanelView/HUDInspectorOverlay；Test Tests/ClipFlowAppTests/QuickPasteInspectorMotionTests.swift。
**Interfaces:**
- QuickPastePanelView保留原参数并增加inspector: InspectorPresentation? = nil；Controller每个面板持有独立实例并传入，不与历史共用当前id。
- QuickPastePanel增加onCancelInspector: (() -> Bool)?；有详情含closing时消费Esc，无详情则维持关闭整个快捷面板。hide/销毁调用reset。
- 详情粘贴只捕获准确ClipboardItem，并在有效关闭完成后执行原onPaste一次；失焦hide取消待执行动作，不回落到第一条。onPasteAction和onClose不得重复关闭。

- [ ] **1 RED测试：** testLastClosingFrameCannotPasteUnderlyingRow：FakeDriver到0.01仍未完成，底层双击pasteCount=0；testEscapeWithWebFocusDismissesInspectorFirst：第一次Esc不关面板，完成后再按才关；testHideOrReopenRejectsOldPasteCompletion：旧完成不影响新窗口或粘贴。
- [ ] **2 运行RED：** swift test --filter QuickPasteInspectorMotionTests。Expected：仍是即时关闭路径，失败。
- [ ] **3 接入与GREEN：** 移除叠加160ms隐式详情动画，复用共用详情而非再造一套；保持激活式NSPanel/阴影/捏合桥/外部目标。补testScrolledOpenClosePreservesOffset、testPinchSurvivesMotion、testRepeatedPasteInvokesExactItemOnce、testReducedMotionAndTransparency。运行本任务测试，Expected：0失败。窗口失焦仍按原策略隐藏，不因鼠标移动关闭。
- [ ] **4 全量：** DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer swift test；git diff --check；zsh -n scripts/build_app.sh；DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer zsh scripts/build_app.sh。Expected：退出0，记录实际通过/跳过数，不预写成功。
- [ ] **5 实机：** 用临时演示数据覆盖两入口的文本/代码/链接/方图/长图/敏感内容，下滚后右键、连续反向开关、Esc/背景/按钮退出、捏合。录制并逐帧检查白雾尾帧、裁剪、形变；用Instruments Animation Hitches观察60fps目标，不把单测/录屏帧率当实测。记录机型/系统/尺寸；无macOS 12或Intel实机则保留验证缺口。
- [ ] **6 收尾提交：** 通过验收才把设计状态改“已实施”，归档实际测试与未覆盖项。只暂存任务文件，git commit -m "feat: unify quick paste inspector cover transition"；不推送/发版/安装，等待用户整合决定。

## 自审与交接

覆盖映射：参考分层→2；双入口→3/4；时长/可中断→1/2；遮罩/滚动/命中→1/3/4；纯白/操作/长图→2/3；捏合/到期/迟到粘贴→1/4。每项Review Focus有对应测试，接口名称与前后任务一致。

执行前用using-git-worktrees建立或确认隔离工作区；不得未经许可直接在main实施。计划中的命令尚未执行。建议当前会话顺序实施：两入口依赖同一状态机，顺序验证更容易定位问题；用户也可明确选择子代理实施与逐项复核。
