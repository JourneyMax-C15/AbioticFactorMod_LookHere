# 更新日志

本文件记录 `Look Here` 从早期开发版本到正式版本的完整变化。

## v1.0.1 - 2026-08-24

### 性能优化

- 监听服务器命中成功后立即完成自己的球体、文字和实体描边，不再等待网络数据包回到主机。
- 坐标改为15位环绕编码：保持4厘米量化精度，并利用500米最大射线距离从接收端玩家附近恢复唯一坐标。
- 完整包从48个广播符号减少到38个，并增加距离边界与校验码保护。
- 每批在同一游戏线程中顺序发送4个符号，将约48次定时调度减少为约10批，同时避免一次性发送全部数据造成单帧尖峰。
- Character、PlayerState 和 GameState 的载体身份在帧开始时缓存，不再为每个符号重复执行多次 Unreal 反射查询。
- 新增批量大小、批次数、参考位置和解码参考距离日志，便于对比实际延迟与安全边界。

### 项目调整

- Mod 正式名称改为 `Look Here`，内部名称及安装目录统一为 `LookHere`。
- 建立独立正式工程目录和可分发压缩包结构。

## v1.0.0 - 2026-08-24

### 正式版本

- 将已经完成双人联机验证、球体与文字同步正常、实体本地解析和描边正常的 v0.3.34 标记为首个正式版本。
- 保留 v0.3.34 的完整功能与传输行为，本次不混入尚未联机验证的性能实验改动。
- 所有参与联机的玩家仍需安装相同版本。

## v0.3.34 无动态锚点引用的多人传输

- 不再把动态创建的 `StaticMeshActor` 作为 RPC 参数。0.3.33 的日志已经证明远端虽然收到了所有广播，但该 Actor 引用始终无效。
- 服务器改用所有客户端都已经拥有的玩家 Character、PlayerState 和 GameState，加上空引用组成四种传输符号。
- 每个数据包包含标记槽位、世界/实体模式、精确组件标志、目标类特征、三维世界坐标和校验码。
- 数据符号严格按顺序发送；客户端校验帧头、符号数量、接收超时、协议版本和校验码，任何不完整数据都不会生成错误标记。
- 解码成功后，每台机器各自创建一个不参与网络复制的本地锚点。墙面命中在本地创建球体和文字；实体命中在本地反查对象并施加描边。
- 新增载体可用性、帧开始、超时、校验失败、坐标解码、本地锚点创建以及最终显示结果日志。

联机验证时，主机和远端客户端都应依次出现以下日志：

1. `Marker packet frame started`
2. `Marker packet decoded`
3. 世界标记：`Marker packet visualization handled: configured=true entity=false`
4. 实体标记：先出现 `Local entity resolver`，随后出现
   `Marker packet visualization handled: configured=true entity=true`

如果只有 `Marker packet receive timeout`，说明可靠载体存在但符号没有收齐；
如果出现 `checksum mismatch`，说明符号发生丢失或乱序；如果服务器出现
`Marker packet carriers unavailable`，日志会同时列出缺少的 Character、
PlayerState 或 GameState。

## v0.3.33 客户端本地目标反向解析

- 将多人显示链路明确拆分为“服务器判定命中并广播描述锚点，所有客户端分别解析本地对象并执行描边、球体和文字”。
- 主机使用服务器保存的权威目标执行本地显示；远程客户端不再要求解析服务器目标 Actor 引用，而是直接恢复自己的本地实例。
- 锚点 Owner 现在固定为一定会网络复制的发起玩家角色，不再保存被标记目标的 Actor 引用；远程客户端不会因为目标没有网络 ID 而拿到空 Owner。
- 新增以复制锚点世界坐标为中心的小范围本地碰撞查询，从客户端自己的场景对象中寻找可见 Mesh、Pawn、NPC、家具或交互实体。
- 本地候选使用“命中点到 Actor 包围盒距离”为主、“到 Actor 原点距离”为次进行排序；只有落在安全距离内的可见实体才能被选中。
- 精确组件标志继续由锚点旋转携带；本地找回父实体后，再从该客户端自己的交互组件中选择距离命中点最近的按钮等子部件。
- 服务器把目标类/资源路径计算为紧凑签名并编码进锚点 Yaw；客户端优先选择类签名一致的本地候选，再用空间距离确定具体实例。
- 类签名只作为候选校验，不把资源路径单独当作实例 ID，避免同一售货机、椅子或家具资源存在多份时选错对象。
- 新增 `Local entity resolver` 日志，输出碰撞查询状态、候选数量、包围盒/原点距离以及最终选择。

## v0.3.32 远程客户端锚点复制与多人诊断

- 修复主机收到有效锚点、远程客户端的 `Broadcast_TriggerPager` 却始终把 `LinkedActor` 解析为空对象，导致客户端看不到自己及其他玩家标记的问题。
- 锚点在延迟生成和完成生成后都会重设复制、移动复制、全局相关性、非 Owner 专属相关性、客户端加载与更新频率，并主动唤醒休眠、强制网络更新。
- 广播改为在锚点生成后约 100、750、1500、2500 毫秒分阶段发送；第一次保持主机响应速度，后续发送等待远程 Actor/NetGUID 映射完成。
- 每个客户端按有效锚点去重；已经显示成功的标记会忽略后续广播，不会重复创建文字、延长描边或重复播放成功音效。
- 新增多人链路日志：本地 Controller/Pawn、Q 请求、服务器接收、锚点复制属性回读、广播计划及每轮发送、客户端有效/无效参数、显示结果与去重结果。
- 修复本地玩家上下文可能被 Controller Tick 提前缓存而不输出 `Local player context selected` 的诊断缺口。

## v0.3.31 联机本地角色绑定修复

- 修复监听服务器中 `UEHelpers.GetPlayerController()` 可能返回朋友的远程 PlayerController，导致主机 Q 无反应、F6 的调试提示反而显示到朋友屏幕的问题。
- Q、F6、HUD 标签与本地成功音效统一使用严格验证的本地玩家上下文：Controller 必须是本地控制器，Pawn 必须是本地控制，并且 Pawn 反查的 Controller 必须一致。
- 不再把 UEHelpers 返回的第一个 PlayerController 直接当成本地玩家；它只作为候选，随后与全部 Controller 一起接受严格筛选。
- 本地 Controller/Pawn 会在验证后缓存，每次使用前重新核验；本地 `ClientRestart` 会清除缓存，远程玩家的 `ClientRestart` 不再重置主机本地状态。
- World 身份优先从实际请求角色取得，避免服务器冷却记录再次依赖可能选错玩家的全局辅助函数。
- 日志新增 `Local player context selected/unavailable`，会记录最终 Controller、Pawn 与筛选结果，便于继续核对联机行为。

## v0.3.30 地图切换冷却时间修复

- 修复返回主菜单并重新进入地图后，World 的 `GetTimeSeconds` 回退、旧请求时间仍被保留，导致出现数千秒错误冷却的问题。
- 客户端冷却现在同时记录 World 身份；World 变化或当前时间小于上次请求时间时，立即清除旧冷却和警告音节流状态。
- 服务器每位玩家的冷却记录改为 `{ Time, WorldKey }`，同样处理 World 变化和时间倒退，不改变玩家之间相互独立的 3 秒冷却。
- `ClientRestart` 时主动清理本地冷却，World/时间检测作为无缝切换情况下的第二层保险。
- 日志会以 `WorldChanged` 或 `TimeWentBack` 明确记录重置原因。

## v0.3.29 无可见 Mesh 的安全球形回退

- 对最终选中的实体目标检查实际可见 Mesh；找不到可见 Mesh 时，不再描边碰撞区，也不再尝试把隐形物体显示出来。
- 这类命中改为保留原始 ImpactPoint，生成与墙面命中相同的球形世界标记和文字。
- 梯子、只有交互区域的独立 Actor 以及父体下也没有可见 Mesh 的对象都会进入该回退。
- 独立且类名包含 `BuildZone` 的 Actor 在更前面的射线阶段始终忽略并重射线，不会生成球体；有有效父 Actor 的 BuildZone 仍提升到家具。
- 有 `CharacterMesh0` 的 NPC、普通家具和可见按钮继续描边真实 Mesh，不受球形回退影响。

## v0.3.28 梯子不可见 Mesh 误报修复

- 实机日志确认 `Ladder_Generic_C` 命中和实体跟踪均正确，失败点是唯一发现的 `FurnitureMesh` 为 `visible=false`，但旧版仍把 CustomDepth 写入计为成功。
- 仅对类名包含 `Ladder_Generic` 的 Actor 要求直接描边组件必须实际可见；不可见占位 Mesh 不再阻止回退。
- 梯子没有可见的直接 Mesh 候选时，改由游戏原生 `OutlineComponent` 尝试处理其特殊显示结构。
- NPC、掉落物及其他实体不套用该可见性限制，避免扩大修复范围。

## v0.3.27 独立透明 BuildZone 过滤

- 修复独立的 `BuildZone_C_5.BuildingZoneHologram` 虽然 `visible=false`，仍会抢先成为实体标记目标的问题。
- 仅对类名包含 `BuildZone` 关键字的对象执行透明辅助判断；普通 NPC 的 `ExternalInteractBox`、按钮交互区和其他不可见碰撞组件不会因此被全局忽略。
- `BuildZone_C` 有有效父 Actor 时继续保留命中，由原有逻辑提升到工作台、家具等父实体。
- `BuildZone_C` 没有父 Actor，并且命中组件与 Actor 内均找不到可见 Mesh 时，才将该 Actor 加入本次忽略列表并重新射线。
- 重射线沿用有限次数和去重保护；日志以 `StandaloneTransparentHelper` 明确记录过滤原因。

## v0.3.26 生成式辅助 Actor 父级提升与多部件椅子修复

- 修复工作台被其内部 `NoBuildZone_GEN_VARIABLE_BuildZone_C` 抢先命中后，只跟踪隐藏 `BuildingZoneHologram`、无法出现可见高亮的问题。
- `BuildZone_C` 类型仅在存在有效的直接父级实体 Actor 时向上提升一层；工作台整体成为重复判断、标签跟踪和描边目标。
- 不进行无限父级遍历，也不会把独立存在的 BuildZone 或相邻世界物体误并入工作台。
- 提升后丢弃辅助 Actor 的隐藏组件，不允许它成为精确描边目标。
- 将办公椅的 `ChairTop` 加入整体 Mesh 候选，与底座 `FurnitureMesh` 同时描边、刷新并按各自原状态恢复。

## v0.3.25 世界球体标签高度修复

- 修复远处墙面球体标记的文字明显悬在球体上方的问题。
- 世界标签位置改为读取球体经过 `SphereScale` 缩放后的实际包围盒顶部，因此球体尺寸变化时文字锚点会同步变化。
- 移除世界球体标签额外叠加的 18 世界单位和 20 屏幕像素向上偏移。
- 固定像素文字框改为以自身中心对齐球体顶部，不再把整个 108 像素高度堆叠在锚点上方。
- 实体标签的包围盒 75% 高度规则保持不变。

## v0.3.24 可见网格描边筛选与电车召回站修复

- 修复 `TramSystem_RecallStation_C_1.Cube` 能被 F6 识别、但无法出现可见描边的问题。
- 将 `Cube`、`ButtonMesh`、`base`、`Monitor` 加入已确认的 Blueprint 可见网格属性候选。
- 直接描边现在只把真正的 `MeshComponent` 计为成功，不再对隐藏的 `AbioticTargetingComponent`、Box、Capsule、Sphere 等碰撞/查询组件写入描边并误报成功。
- 指向电车召回站主体时描边 `Cube`；指向其独立召回按钮时描边 `ButtonMesh`。
- 如果 Actor 没有可发现的可见 Mesh，直接描边返回失败并允许原生 OutlineComponent 回退，不再被隐藏组件阻止回退。

## v0.3.23 玩家自身与手持装备射线过滤

- Q / 鼠标中键射线现在显式忽略发起标记的玩家 Pawn。
- 手持武器是独立 Actor，仅忽略 Pawn 仍会先命中武器；本版会沿命中 Actor 的 `Owner`、`AttachParentActor`、`ParentActor` 关系判断是否归属于发起玩家。
- 命中发起玩家所属装备时，将该 Actor 加入忽略列表并重新执行射线，使后方真正瞄准的电脑终端、地图、按钮等对象可以被选中。
- 只排除发起标记玩家自身的层级，不排除其他玩家、敌人或普通世界实体。
- 重试最多跳过 8 个玩家所属 Actor，避免异常父级关系造成无界循环；调试日志会输出 `Ignored requesting-player-owned trace actor and retrying`。

## v0.3.22 球形补偿误选非交互灯具修复

- 修复 `InteractionSphere` 将 `LightFixture_Generic_C.LightMesh` 这类不可交互 Blueprint Actor 当作实体目标的问题。
- 球形补偿候选现在必须由命中组件或所属 Actor 实现交互接口；否则不能覆盖精确直线射线结果，也不能在精确射线无结果时单独创建标记。
- `Button_LightSwitch_C.ButtonMesh` 的 Mesh 本身无需实现接口，只要所属按钮 Actor 可交互，仍可正常选择和描边。
- 增加精确命中与球形补偿仲裁日志，后续可直接确认被保留或拒绝的对象。
- 将 `SM_ResourceNode` 加入明确网格候选；`Resource_MicroNode` 资源节点先执行游戏原生 OutlineComponent 初始化，再应用可维护、可归还的直接描边。
- 首次直接写入后记录实际组件名称以及回读的 CustomDepth、Stencil、注册和可见状态，避免仅凭无异常返回误判描边成功。

## v0.3.21 父网格遮挡按钮命中修复

- 修复 `VendingMachine_BP_C_2` 的 `FurnitureMesh` 比按钮靠前约十几单位，导致正常 Q 射线选择父网格的问题。
- 同时保留各 Trace Channel 的最佳交互组件候选；按钮与最近父网格属于同一 Actor 且位于 60 单位容差内时，优先选择按钮。
- `InteractionSphere` 命中同一 Actor 的普通父网格时，不再覆盖已经找到的精确交互组件。
- 不同 Actor 或墙体后的按钮不会被提升，避免产生穿墙选择。

## v0.3.20 英文冷却与重复提示

- 冷却提示改为纯英文 `Marker cooldown: 2.4s remaining`，避免中文字体或编码异常。
- 显示的是本次触发瞬间实际剩余时间，保留一位小数；客户端预检查和服务器权威拒绝都会提供剩余秒数。
- 重复目标提示改为纯英文 `Target already marked`。
- 可在 `config.lua` 中通过 `CooldownWarningTextFormat` 和 `DuplicateMarkerWarningText` 修改文字。

## v0.3.19 精确交互组件标记修复

- 修正 `VendingButton_BP_C` 实际位于 `HitResult.Component`、并非子 Actor，导致 0.3.17 精确分支被跳过的问题。
- 同时支持实现 `I_Interactable` 的子 Actor 与组件；父体存在多个交互对象时，以命中的具体组件作为描边和重复判断目标。
- 精确组件标志通过隐藏实体锚点的旋转复制；各客户端根据父 Actor、锚点命中位置和交互组件集合还原同一个按钮。
- 直接描边可只接管一个 `PrimitiveComponent`，不会再因按钮命中而枚举整台售货机的网格。
- 精确组件文字使用组件世界位置；按钮移动时会随组件位置更新。

## v0.3.18 可见的拒绝原因

- 冷却期间再次触发标记时，游戏原生警告 UI 显示“标记正在冷却”，并保留原警告音。
- 重复标记同一最终目标时，游戏原生警告 UI 显示“该目标已被标记”，并保留拒绝蜂鸣音。
- 两段文字均可通过 `config.lua` 的 `CooldownWarningText` 和 `DuplicateMarkerWarningText` 修改。

## v0.3.17 交互层级、动态归还与重复判断

- 使用游戏 `I_Interactable` 接口和父子 Actor 关系识别独立交互目标。
- 父 Actor 下存在多个交互子 Actor 时，只标记并描边当前子目标；只有一个交互子目标时提升为父 Actor；直接命中父 Mesh 时仍描边父 Mesh。
- 售货机的 `Button_0`、`Button_1` 等按钮成为独立标记目标，不再因为命中按钮而描边整台售货机。
- 直接描边每次续期前观察非 Mod 的 CustomDepth/Stencil 状态，并记录游戏最近一次外部变化。
- 到期时仅在组件仍保持 Mod 的 `true/250` 签名时归还最近外部状态；若游戏或其他 Mod 已接管，则不再覆盖。
- 服务器按最终交互目标执行全局重复判断。有效期内重复标记不创建锚点、不占编号、不续期，并向发起者播放拒绝蜂鸣音。
- 复杂父物体的不同按钮拥有不同目标键；Pawn/NPC、独立掉落物和单交互物体仍按最终 Actor 去重；世界位置不去重。

## v0.3.16 掉落物 WorldMesh 精确命中

- F6 实测确认掉落物 Actor 为 `Abiotic_Item_Dropped_C`，可见碰撞组件为 `WorldMesh`。
- `WorldMesh` 会忽略原正常标记使用的 Visibility/TraceChannel0，但响应 `TraceChannel2` 的简单碰撞。
- 正常 Q/鼠标中键射线只额外增加一次 `TraceChannel2-Simple` 查询，并与原结果按距离选择最近命中；不会运行 F6 的全层扫描。
- 将 `WorldMesh` 加入直接 CustomDepth 描边候选，掉落物命中后可直接描边并在到期时恢复原状态。
- F6 屏幕列表过滤玩家所在、距离为 0 的 `AbioticLevelStreamingVolume` 噪声；完整结果仍写入日志。

## v0.3.15 F6 全碰撞诊断射线

- 调试状态默认关闭；按 `F5` 开启或关闭。关闭时 `F6` 完全不执行查询，也不显示任何内容。
- 新增完全独立的 `F6` 调试功能，不创建 Mark、不使用冷却，也不改变 Q/鼠标中键的正常射线。
- 沿准星射线检查 `0–31` 全部对象类型以及 `0–31` 全部 Trace Channel。
- 每种查询同时执行简单碰撞和复杂碰撞模式，共计 66 次只读查询；仅在调试已开启且主动按下 F6 时执行。
- 对结果按 Actor 与 Component 去重并按距离排序，屏幕分行显示最近 4 组命中；名称会截断，避免文字超出屏幕。
- `UE4SS.log` 记录所有唯一命中的完整 Actor 类、Component 类和来源通道，便于确认医疗包或掉落物使用的专用碰撞层。
- Q/鼠标中键的标记文字始终只显示 `<用户名> Mark N`，不再追加目标名称和调试信息。
- 成功提示使用游戏 Pager 点击音；冷却拒绝继续使用警告蜂鸣音，两者不再相同。
- 如果对象及其交互组件均为 `NoCollision`，任何物理射线都无法命中；此时 F6 会明确显示没有对应碰撞结果。

## v0.3.14 小型交互物命中与本地声音

- 在精确 Visibility/对象射线之外增加半径 `12` 单位的小型对象球扫，用于捕获墙上医疗包等体积较小或只提供交互碰撞的物体。
- 球扫结果只有在命中实体且与原墙体命中相距不超过 `60` 单位时才可抢占，避免选中墙后较远物体。
- 冷却期间再次按键会调用游戏原生 `Client_DisplayWarningMessage` 警告提示音，但不会发送服务器请求或改变现有标记。
- 同一次按键因 Ctrl/Shift 组合触发多个绑定时，警告音按 `0.25s` 限流，避免重叠播放。
- 标记成功后，等待有效的服务器 Broadcast 返回，再为发起者本机补播一次确认音；其他玩家仍使用游戏原生 Pager 声音。
- 远端原本能听到的声音并非 Mod 主动播放，而是复用游戏 `Broadcast_TriggerPager` 时由原生蓝图产生。

## v0.3.13 描边回收与命中覆盖修复

- 可直接访问目标网格时只使用直接 CustomDepth 描边，不再同时续租原生 OutlineComponent，避免同一个标记存在两套互相独立的到期计时器。
- 直接描边到期后恢复每个网格原始的 CustomDepth 与 Stencil，并输出明确的恢复数量日志。
- 描边记录同时使用世界时间和本地墙钟时间兜底，切换世界或世界时间回退时不会让旧记录长期残留。
- 冷却期按键只记录拒绝原因，不创建标记、不刷新描边，也不改变已有描边的生命周期。
- 对象类型兜底射线由 `WorldDynamic + Pawn` 扩展为 UE 六种标准对象类型，并继续选择离视点最近的命中。
- 当 UE4SS 无法枚举组件数组时，除 `FurnitureMesh` 外还尝试 `DoorMesh`、`ItemMesh`、`StaticMesh`、`Mesh` 与 `SkeletalMesh`，且只接受真正的 PrimitiveComponent。

## v0.3.12 方案 2：直接 FurnitureMesh 描边

- 当 UE4SS 无法枚举 Actor 的 PrimitiveComponent 时，额外读取 Blueprint 暴露的 `FurnitureMesh`。
- 保存该网格原始的 CustomDepth 与 Stencil，并写入实测成功状态 `CustomDepth=true, Stencil=250`。
- 直接写入发生在原生 `ToggleOutlineOverlay` 之后，解决未触发交互时原生函数成功返回但保持 `false/0` 的问题。
- 描边有效期内继续以 `0.25s` 低频重设直接状态，到期恢复网格原值。
- 增加 `after_direct` 诊断快照，便于确认远处未交互售货机是否立即变为 `true/250`。

## v0.3.11 Outline 初始化诊断

- 每次实体 Mark 在原生 `ToggleOutlineOverlay` 前后各输出一条状态快照。
- 记录 OutlineComponent 是目标原有还是 Mod 新建、组件注册状态、内部 `Registered`、`ComponentEnabled`、`RegisteredComponents` 与待处理组件数量。
- 记录目标 Actor 的 PrimitiveComponent 集合可见数量，以及 `FurnitureMesh` 的注册、CustomDepth 和 Stencil 状态。
- 周期性描边续租不重复打印诊断，避免每 `0.25s` 刷屏。
- 本版只补充观测信息，不主动调用交互初始化函数，也不改变高亮策略。

## v0.3.10 实体描边续租

- 实体标记存续期间每 `0.25s` 重新声明一次黄色原生 Outline 和直接 CustomDepth。
- 游戏交互高亮覆盖标记状态后，Mod 会在下一次低频刷新时恢复标记描边。
- 每次续租只使用标记原本剩余的持续时间，不会把描边延长到 Mark 到期之后。
- 复用现有集中玩家 Tick，不创建新的延迟回调，也不进行逐帧重设。
- 包含 v0.3.9 的 `Q`、`Ctrl+Q`、`Shift+Q`、`Ctrl+Shift+Q` 绑定。

## v0.3.9 Q 键修饰键兼容

- 保留无修饰键的 `Q` 标记。
- 增加 `Ctrl+Q`、`Shift+Q` 和 `Ctrl+Shift+Q`，蹲伏或奔跑过程中也能标记。
- 所有组合调用同一个标记请求并共享现有的本地、服务器每玩家 3 秒冷却，不会绕过限流。
- 本版不调整实体跟踪和 HUD 投影性能方案。

## v0.3.8 实体文字垂直对齐

- 实体文字的世界锚点精确设为包围盒从底部计算约 `75%` 的高度。
- 取消实体文字额外的 18 单位世界上移和 20 像素屏幕上移。
- TextBlock 改为以自身垂直中心对齐锚点，不再把整个文字区域放在锚点上方。
- 墙壁、地面等圆球世界标记维持原有文字位置。

## v0.3.7 字体显示调整

- HUD Mark 文字的屏幕空间缩放从 `1.25` 调整为 `2.5`，字体视觉尺寸扩大一倍。
- TextBlock 字体样式切换为 `Bold`，普通标记和主机调试附加信息统一加粗。

## v0.3.6 实体文字生命周期修复

- 每个本地 Mark 文字记录与描边相同的明确到期时间。
- 到达 `MarkerDuration` 后立即从 HUD 删除，不再只等待复制锚点的 UObject 包装失效。
- 修复实体仍然存活时 Mark 文字长时间残留，而描边已经消失的问题。
- 实体文字的包围盒高度和异常回退高度均调整为原来的一半，使文字整体向下移动。
- 新增 `F5` 运行时开关主机调试附加信息，并立即刷新当前已有文字；远程客户端仍只显示正常 Mark。

## v0.3.5 实体文字与静态道具高亮修复

- 实体文字包围盒不再包含 Child Actor，避免异常组件把文字投影到屏幕上方不可见区域。
- 对异常偏移或异常高度的实体包围盒增加校验，失败时改用实体原点上方的稳定固定高度。
- 售货机、部署桌子等独立 Blueprint Actor 现在走实体分支：高亮目标并让 Mark 文字持续跟踪目标。
- 引擎原生 `StaticMeshActor` 仍视为墙壁、地面等世界结构，继续显示命中点圆球。

## v0.3.4 实体命中修复

- 保留 Visibility 通道射线用于墙壁、地面和普通世界碰撞。
- 增加 `WorldDynamic` 与 `Pawn` 对象类型射线，捕获忽略 Visibility 的 Pawn、Actor 和动态实体。
- 两路射线同时命中时按距射线起点的真实距离选择最近结果，实体后方墙体不再抢占标记。
- 从命中对象和 Component 的 `Owner`、`Outer` 链向上解析真正 Actor，兼容 UE5.4 的 HitObjectHandle 表现。
- 主机调试标签与日志增加射线来源：`Visibility` 或 `WorldDynamic+Pawn`。
- 所有解析结果仍必须通过 Actor 类型验证，保留 v0.3.3 的 `SetOwner` 原生崩溃保护。

## v0.3.3 原生崩溃修复

- 修复 v0.3.2 在命中普通静态物体后调用 `AActor::SetOwner` 发生原生访问冲突的问题。
- 所有 Owner 候选必须先通过 `/Script/Engine.Actor` 的 `IsA` 验证。
- 世界标记恢复使用请求玩家作为 Owner，不再把原始世界命中引用写入复制 Owner。
- 只有严格验证后的实体 Actor 才能作为 Owner，用于远程实体追踪和描边。
- UE5.4 命中 Actor 提取会依次检查 Actor、HitObjectHandle 和命中 Component 的 Owner，并拒绝非 Actor 引用。
- 保留 Q 键、鼠标中键、每玩家独立 3 秒冷却及 v0.3.1 的性能优化。

## v0.3.2 双触发键

- 新增 `Q` 键触发位置标记。
- 保留鼠标中键，两种按键调用同一标记流程。
- 两种按键共享本地与服务器的每玩家 3 秒冷却，不能通过交替按键绕过限制。

## v0.3.1 性能与联机保护

- 每位玩家拥有独立的服务器权威 3 秒冷却；一名玩家的冷却不会影响其他玩家。
- 客户端同时使用 3 秒预过滤，服务器仍负责最终裁决。
- 运行期间不再为每个标记创建多组 `ExecuteWithDelay` 回调，改由一个现有玩家 Tick 集中处理广播、实体重试和描边恢复。
- 世界标记只执行一次可视化，不再固定重复执行 50ms、250ms 两轮描边。
- 实体标记仅在目标 Owner 尚未复制到本地时进行最多三次轻量重试。
- 本地 UI 按 1–8 槽位硬回收；同编号新标记到达时立即删除旧文字，避免标签堆积。
- `ScreenToWidgetLocal` 若在当前 UE4SS 中不可调用，只失败检测一次，后续永久使用已实机验证的 DPI 回退，不再每帧抛出异常。
- HUD 更新频率从约 30Hz 调整为 20Hz，八个标记同时存在时显著减少 UI 开销。
- 目标名称、Actor 类和 Component 类调试信息只在主机端显示；远程客户端始终只显示正常标记文字。

## v0.3.0 调试目标信息

- 射线结果现在同时保留命中的 Actor 与具体 Component，不再只记录 Actor。
- 启用 `DebugDisplayTargetInfo` 时，标记第二行显示：目标名称、命中分类、Actor 类和 Component 类。
- 示例：`Target: BP_Enemy_C_2 | Entity | BP_Enemy_C | SkeletalMeshComponent`。
- 世界标记的复制锚点也会通过 Owner 保留原始命中 Actor；远端客户端可据此显示同一目标信息。
- 日志新增 `Trace hit` 诊断，可直接确认目标为何被判定为 `Entity`、`StaticMesh` 或 `WorldActor`。
- 设置 `DebugDisplayTargetInfo = false` 后，标签恢复为单行 `<玩家名> Mark <编号>`；该开关与日志开关相互独立。

## v0.2.9 修复

- v0.2.8 已实机确认文字显示并持续追踪，但 Crosshair 子画布局部坐标与视口坐标存在较大偏移。
- 优先从运行时 `W_PlayerHUD_Main_C` 获取全屏 `PrimaryHUDCanvas`。
- 使用 `ScreenToWidgetLocal` 按目标画布 CachedGeometry 将屏幕投影坐标转换成真实局部坐标。
- Crosshair 回退同样使用几何转换，不再仅靠 DPI 除法猜测坐标原点。
- 日志增加局部坐标、转换模式和转换失败诊断。

## v0.2.8 修复

- v0.2.7 选中了 `/Game/...:WidgetTree` 下的 Blueprint 模板画布，导致控件创建和移动成功但屏幕不显示。
- 只接受 `GetWorld()` 有效的运行时 Widget/CanvasPanel，彻底排除资源模板。
- 优先查找运行中的 `W_HUD_Crosshair_C`，优先选择 `IsInViewport()` 为真的实例。
- 从运行时实例通过 `GetWidgetFromName` 或 `WidgetTree:FindWidget` 获取真实 CanvasPanel。
- 回退枚举同样要求有效游戏世界，并记录运行时候选数量和实例完整路径。

## v0.2.7 修复

- v0.2.6 实机日志确认玩家控制器上的 `PrimaryHUDCanvas` 字段为空。
- 增加运行时 CanvasPanel 发现：先检查控制器和 Pawn，再枚举有效 CanvasPanel。
- 优先选择名称含 `PrimaryHUDCanvas` 的实例，其次选择正在显示的 Crosshair/HUD 根画布。
- 排除类默认对象和 Waypoint 自身画布，并记录候选数量、评分及最终对象路径。

## v0.2.6 修复

- v0.2.5 实机日志确认游戏从不执行传统 `HUD:ReceiveDrawHUD`，因此停用该方案。
- 参照 Ammo Counter Mod 已验证的控件克隆方式，从游戏原生 TextBlock 模板克隆独立文字。
- 把文字直接加入玩家控制器的 `PrimaryHUDCanvas`，其 CanvasPanelSlot 完全由 Mod 所有。
- 在已验证持续运行的玩家控制器 Tick 中投影世界位置，并通过 `SetOffsets` 更新文字位置。
- 增加 PrimaryHUDCanvas 类型、TextBlock 创建和 Slot 移动诊断。

## v0.2.5 修改

- 停用无法可靠移动的原生 `W_Waypoint_Generic` UMG 文字控件。
- 改为 Hook `HUD:ReceiveDrawHUD`，每帧把复制锚点或实体顶部投影到屏幕并通过 Canvas 绘制文字。
- Canvas 文字固定屏幕像素大小、始终正对玩家并天然穿透场景遮挡。
- 使用带黑色阴影和黑色描边的高亮文字，不再显示原生 Waypoint 图标。
- 玩家名按确定性调色板映射颜色，同一单局中同一玩家保持同色。
- 增加 HUD Hook、字体、投影及首次绘制结果诊断日志。

## v0.2.4 修复

- v0.2.3 实机日志确认视口、投影坐标和 Render Translation 均有效，但仍被更晚执行的 Widget 更新覆盖。
- 直接 Hook `W_Waypoint_ParentBP:UpdatePosition`，在游戏 Waypoint 完成自身位置重置后重新应用 Mod 投影位置。
- 新增 Waypoint 位置 Hook 注册及首次执行诊断。

## v0.2.3 修复

- v0.2.2 实机日志确认世界坐标投影和 CanvasSlot 写入均成功，但游戏 Widget Tick 会把布局位置重置回屏幕中心。
- 改为对包含文字的 `WaypointRoot` Overlay 应用屏幕中心相对的 Render Translation，绕过 CanvasSlot 重置。
- 投影诊断增加视口尺寸、位置模式和实际渲染位移。

## v0.2.2 修复

- 根据 v0.2.1 实机日志，修复已注册但从未执行的位置更新 Hook。
- 玩家控制器 Blueprint `ReceiveTick` 恢复为 UE4SS 所需的单回调注册形式。
- 保留首次投影、CanvasSlot、位置写入和文字控件诊断日志。

## v0.2.1 修复

- 修正玩家控制器 Tick Hook 路径：`Blueprints/Characters` 改为真实的 `Blueprints/Meta`。
- 同时隐藏 `WaypointIcon` 和父控件拼错的 `WaypoointIcon`，只保留标记文字。
- 创建控件时立即强制显示文字；随后在游戏自身 Tick 之后持续恢复文字可见性、透明度和投影位置。
- 增加首次屏幕投影、坐标和 CanvasSlot 诊断日志。

## v0.2.0 修改

- 单局使用一个全局共享的 8 槽标记池。
- 主机按 `1 → 8 → 1` 循环分配编号，所有客户端看到相同编号。
- 标签显示为 `<玩家名> Mark <编号>`。
- 第 9 个标记会复用编号 1，并销毁仍占用该槽位的旧标记，确保同时最多存在 8 个锚点。
- 编号编码在复制锚点的 Roll 旋转中，不增加新的网络 RPC 参数，也不改变球体外观。

## v0.1.9 修改

- 标签文字简化为 `<玩家名> Mark`。

## v0.1.8 修复

- 修复直接 `AddToViewport()` 后原生 Waypoint 图标停在默认位置的问题。
- 改 Hook 游戏实际存在的 `Abiotic_PlayerController:ReceiveTick`。
- 每 0.033 秒把锚点或实体包围盒顶部投影到屏幕，并直接移动 `WaypointRoot`。
- 持续恢复标签文字，避免控件 Blueprint 把文字覆盖为空。
- 强制隐藏原生图标、箭头和进度条，只显示文字。

## v0.1.7 修复

- 文字从世界空间 `TextRenderComponent` 改为游戏原生 `W_Waypoint_Generic` 屏幕 UI。
- UI 直接跟踪复制到本地的标记锚点，始终正对屏幕，不再依赖失效的 `PlayerTick` Hook。
- 使用游戏中已确认存在的 `Abiotic_PlayerController:ReceiveTick`，手动将目标世界坐标投影到屏幕并移动 `WaypointRoot`。
- 每次 UI 更新都会重新写入标签文字并隐藏原生图标、箭头和进度条，防止控件 Blueprint 初始化覆盖 Mod 设置。
- 文字大小成为固定 UI 尺寸，不随世界距离改变。
- 文字位于屏幕 UI 层，可穿透墙体显示，同时不参与球体 CustomDepth 描边。
- 原 TextRender 仅保留为原生 Waypoint UI 创建失败时的诊断后备。
- 命中墙壁、地面或普通静态物体时继续显示描边球体。
- 命中 Pawn 或带 SkeletalMesh 的实体时隐藏球体，改为对目标全部 PrimitiveComponent 写入描边，并同时调用游戏原生 OutlineComponent。
- 实体引用通过隐藏的复制锚点 Owner 同步到所有客户端，Waypoint 文字直接跟踪目标实体移动。
- 直接写入的实体 CustomDepth 会在标记持续时间结束后恢复原值；重复标记会延长当前实体描边时间。

## v0.1.6 修复

- 文字关闭 Custom Depth，不再套用球体的描边效果。
- 文字目标高度提高到约 80 屏幕像素。
- 使用统一的玩家控制器 Tick 更新全部有效标签，按实时距离、视野角和分辨率换算世界字号；移动相机时文字视觉尺寸保持稳定。
- 统一更新器每 0.05 秒运行一次，不再为每个标签创建递归定时器。
- 标签使用纯英文，避免 TextRender 默认字体把中文显示成缺字特殊字符。
- 清理玩家名尾部的 ASCII 控制字符，同时保留中文和可见符号。

## v0.1.5 修复

- 玩家名改用 `FString:ToString()`，不再显示 `FString: 0000...` 对象地址。
- 移除每个文字各自创建的无限递归定时器，避免 UE4SS EngineTick 回调失效后所有后续标记停止显示。
- 显著增大文字，并设为高亮黄色。
- 模式 5 的直接 Stencil 改用位掩码 `32`；其最终颜色等待实机确认。

## v0.1.4 修复

- 按 UE4SS 对 Blueprint UFunction 的实际 Hook 语义修正网络流程：唯一回调执行完服务器射线和锚点生成后，直接延迟 Multicast 有效锚点。
- 文字传参改为显式 `FText`。

## v0.1.3 修复

- 修复 v0.1.2 中原生 Broadcast 仍收到空 `LinkedActor` 的问题：服务器生成锚点后延迟发送一次带有效 Actor 的 Multicast。
- 每个客户端为锚点本地创建文字：`<玩家名> 标记了这里`。
- 文字自动朝向本地摄像机，并按距离补偿世界字号；文字同时写入 Custom Depth Stencil。

## v0.1.2 修复

- 直接为球体网格写入非零 Custom Depth Stencil，不再只依赖动态挂载的游戏原生 `OutlineComponent`。
- 为 Broadcast、球体配置、Stencil 和原生描边调用增加分阶段诊断日志。

## v0.1.1 修复

- 兼容当前安装的 UE4SS：对象有效性检查改用 UObject 自带的 `:IsValid()`，不再调用不存在的全局 `IsValid()`。
- 该问题曾使 v0.1.0 在注册 Pager Hook 前中止，因此 v0.1.0 实际尚未执行到射线、网络 RPC 或描边阶段。
