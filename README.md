# FPS_GAS

基于 **Unreal Engine 5.8** C++ 开发的多人射击原型：用 **GAS（Gameplay Ability System）** 承载属性、伤害与技能，用 **Steam P2P 会话**完成联机。

> **项目状态：学习 / 个人原型（Personal Prototype）**
> 当前版本是围绕 GAS 接入和联机骨架的工程验证，**不是生产就绪系统**，也不适合直接作为商业发行基础。默认使用 Steam 官方测试 AppID `480`（Spacewar），仅供本地与好友联机调试。

---

## 项目定位

本项目参考大型 UE 工程的模块化思路，把 FPS 的核心能力拆成可独立替换的层：

- **Gameplay 框架层**：GameMode / GameState / PlayerState / PlayerController / GameInstance 的职责划分；
- **GAS 层**：AttributeSet 数值、GameplayEffect 结算、GameplayAbility 技能、GameplayCue 表现；
- **组件层**：Combat、Health、Elimination 三个 ActorComponent 承担具体玩法逻辑；
- **联机层**：Steam 会话管理、Server RPC 权威结算 + NetMulticast 表现；
- **表现层**：UMG 控件（血条 / 弹药 / 准星 / 计分板 / 连杀提示）。

**关键原则：数值权威归属于 GAS，交付给确定性 C++ 代码；表现层只做单向读取，不反向写回数值。**

这条原则的具体落法是：`UFPSAttributeSet` 持有 Health / Shield 的真值，`UHealthComponent` 从"数值持有者"**降级为"GAS → 现有 UI 与死亡流程"的适配层**，由 `SetFromGAS()` 单向驱动。

---

## 已实现能力

### GAS 核心

- `UFPSAttributeSet`：`Health` / `MaxHealth` / `Shield` / `MaxShield` 四个复制属性（`ReplicatedUsing` + `COND_OwnerOnly`），外加不参与聚合的元属性 `IncomingDamage`；
- **先扣护盾、溢出扣血**：在 `PostGameplayEffectExecute` 里对 `IncomingDamage` 分流，一次性结算完成；
- `PreAttributeChange` 对 Health / Shield 做 `Clamp(0, Max)`，并带 `GetMaxHealth() > 0` 保护（防止初始化顺序导致的清零）；
- 自定义 ASC `UFPSAbilitySystemComponent`：`SetIsReplicatedByDefault(true)`，预留 `Ability.ActivateOnGiven`（带此标签的能力在授予/复制到达时自动激活）；
- GA 基类 `UFPSGameplayAbility`：统一 `InstancedPerActor` + `NetExecutionPolicy = ServerOnly`，与工程既有的"客户端播表现 + 服务端权威结算"模式保持一致；
- 三个用 C++ 固化结构的 GE 子类：`UFPSDamageEffect`（子弹直击）、`UFPSDamageOverTimeEffect`（燃烧 DoT，Duration + Period + Stacking 规则写死在构造函数）、`UFPSResetAttributesEffect`（重生重置，用 AttributeBased 的 `FGameplayEffectAttributeCaptureDefinition` 读取目标上限）。

### 玩法能力

- **烟雾弹**：`UFPSAbility_Smoke` 服务端 `SpawnActor<AFPSmokeCube>` 并按视线方向 `Launch`，落地后放大、计时销毁；`Cooldown.Smoke` 通过 `ActivationBlockedTags` 控制节奏；
- `AFPSmokeCube` 是 `bReplicates = true` + `SetReplicateMovement(true)` 的 Actor，**只遮挡视觉、可穿越、不挡子弹**；
- **武器系统**：`AWeapon` + `UCombatComponent`，支持手枪 / 步枪、瞄准、换弹、切枪、弹药补充；
- **持续伤害**：步枪命中附带 5 秒燃烧，每 0.5 秒跳一次；
- **连杀与特殊击杀**：`UEliminationComponent` 按连杀数触发 `ESpecialElimType`（`meta=(BitFlags)` + `ENUM_CLASS_FLAGS`）。

### 联机

- `MultiplayerSessions` 插件提供 `UMultiplayerSessionsSubsystem`（`UGameInstanceSubsystem`），封装 `CreateSession` / `FindSessions` / `JoinSession` / `StartSession` / `DestroySession`；
- 房主 `ServerTravel` 进入对战图（自动拼 `?listen`），客户端 `ClientTravel` 到解析出的连接串；
- RPC 分工明确：`Server_*` 处理输入意图与权威结算，`Client_*` 只做本机 UI 与提示，`NetMulticast_*` 广播开火 / 换弹 / 切枪 / 受击表现；
- 复制条件精细化：护盾与血量 `COND_OwnerOnly`（他人不可见），瞄准状态 `COND_SkipOwner`（自己不需要同步）。

### 存档与数据

- `UFPSGameInstance` 负责存档读写，槽位名 `PlayerProfile`；
- `UFPSPlayerSaveGame` 字段：`PlayerName` / `HighestKillsInMatch` / `HighestKillStreak` / `Wins`；
- `UWeaponData` / `USpecialElimData` 用 DataAsset 承载配置，把数值从代码里摘出来。

### 工程与协作

- GameplayTag 用 **NativeGameplayTags 宏**声明（C++ 编译期注册），不走 `DefaultGameplayTags.ini`；
- 自定义碰撞通道 `ECC_GameTraceChannel1` 命名为 `Weapon`，并令 Pawn 忽略该通道；
- 完整的 GAS 接入操作清单（`记录AI过程/GAS_Setup.md`）与 UE 5.8 销毁顺序实测文档（`GameplayFrame/`）。

---

## 未实现

**尚未实现**

- 无自动化测试：`Source/` 下没有任何 `IMPLEMENT_SIMPLE_AUTOMATION_TEST` / `functional test`，当前全靠 PIE 手动验收；
- 无 Dedicated Server 支持，联机以 Steam P2P 为主；
- 无匹配队列、排位、反作弊、举报系统；
- 无存档云同步，档案仅落本机磁盘；
- 房间类型（`Capture the Flag` / `Free For All` / `Teams`）**不改变任何玩法规则**——血量、武器、伤害完全一致，它只是一个 `FString` 房间标签，唯一作用是配对过滤：客户端只加入 `MatchType` 与自己勾选一致的房间；
- 好友权限：现有框架下无法实现"Teams 房只让好友进"这类真正的准入控制（需改 `FOnlineSessionSettings` 的 `bShouldAdvertise` / `bAllowJoinViaPresence`，或改用 Steam Lobby 的 `LobbyType`）。

---

## 架构概览

```text
                          Client (Player)
                                |
                     Enhanced Input (IMC_FPS / IA_*)
                                |
                +---------------+----------------+
                |                                |
        AFPS_Controller                  AFPSCharacter
        (Server_SetPlayerName)     (IAbilitySystemInterface 转发)
        (Server_RequestStartMatch)              |
        (Client_ShowMatchMessage)               |
                                                |
      +----------------+----------------+-------+--------+----------------+
      |                |                |                |                |
UCombatComponent  UHealthComponent  UMG Widgets   UEliminationComp   AWeapon
开火/瞄准/换弹     GAS→UI 适配层     血条/弹药/    连杀计数/         武器数据
切枪/伤害结算      SetFromGAS()      准星/计分板   特殊击杀          DataAsset
      |                |                |
      |                |                +--> 单向读取，不反向写回
      |                |
      |                +<--- PushToHealthComponent (OnRep)
      |                              |
      +------------------------------+
                                     |
                          AFPSPlayerState  (IAbilitySystemInterface)
                                     |
                      UFPSAbilitySystemComponent  (ReplicationMode = Mixed)
                                     |
                +--------------------+--------------------+
                |                    |                    |
        UFPSAttributeSet      UFPSGameplayAbility     GameplayEffect (C++)
        Health/MaxHealth      (InstancedPerActor,     FPSDamageEffect
        Shield/MaxShield       ServerOnly)            FPSDamageOverTimeEffect
        IncomingDamage              |                 FPSResetAttributesEffect
                              UFPSAbility_Smoke             |
                                    |                 SetByCaller: Data.Damage.*
                              AFPSmokeCube          (值恒为负，Modifier = Additive)
                              (Replicates)

                          ---- 会话层 ----
                          UMenu (UMG)
                              |
                UMultiplayerSessionsSubsystem (GameInstanceSubsystem)
                              |
                     OnlineSubsystemSteam / SteamSockets
                              |
                  ServerTravel(?listen) / ClientTravel
```
---

## 项目结构

本仓库 `FPS_GAS` 是**工作区总仓库**，UE 工程以 **git submodule** 形式引入：

```text
FPS_GAS/                              工作区总仓库（本仓库）
├── FPS_NetWork0/                     UE 5.8 工程 —— submodule，指向 FPS_NetWork0.git
│   ├── FPS_NetWork0.uproject         EngineAssociation 5.8
│   ├── Source/FPS_NetWork0/          C++ 主模块（30 组 .h/.cpp）
│   │   ├── AbilitySystem/            ASC / AttributeSet / Abilities / Effects / Smoke
│   │   ├── Character/                AFPSCharacter
│   │   ├── Combat/                   UCombatComponent / UEliminationComponent
│   │   ├── Data/                     WeaponData / SpecialElimData / FPSPlayerSaveGame
│   │   ├── Game/                     FPSGameMode / FPSGameState / FPSGameInstance
│   │   ├── Health/                   UHealthComponent（GAS 适配层）
│   │   ├── Interfaces/               IPlayerInterface
│   │   ├── Library/                  MyBlueprintFunctionLibrary
│   │   ├── Player/                   AFPSPlayerState / AFPS_Controller
│   │   ├── ShooterTypes/             共享枚举与结构（ETurning / ESpecialElimType / FReticleParams）
│   │   ├── Tags/                     ShooterGameplayTags（NativeGameplayTags 声明与定义）
│   │   ├── UI/                       6 个 UMG C++ 基类
│   │   └── Weapon/                   AWeapon（EFireType / EWeaponStatus）
│   ├── Plugins/MultiplayerSessions/  Steam 会话管理插件（第三方教程插件 + 本地魔改）
│   ├── Config/                       DefaultEngine / DefaultGame / DefaultInput
│   └── Content/                      地图、蓝图、材质、Niagara、音频、输入资产
├── GameplayFrame/                    UE 5.8 Actor 销毁顺序与回调时机（引擎源码实测）
├── 记录AI过程/                        AI 协作记录
│   ├── GAS_Setup.md                  GAS 接入操作清单（编辑器侧 12 步建资产 + 验收 + 故障对照）
│   ├── Grill_GAS/                    GAS 设计问答（5 轮 grill-me）与待办
│   ├── Grill_Data/                   存档 / 排行榜 / GameMode 设计问答
│   └── Question.txt                  过程中的未解疑问
├── .agents/unreal-engine-skills/     24 个 UE Agent 技能（第三方，MIT）
└── link_ue_claude_skills_commands.ps1 把技能目录 Junction 到 .claude/skills
```

**不在仓库内**（已在 `.gitignore` 排除）：

- `Windows/` —— 打包成品，约 1.3 GB（含 329 MB exe 与 367 MB pdb）；
- `.claude/` —— 本机私有 AI 配置；
- `FPS_NetWork0/` 内部的 `Binaries/` `Intermediate/` `Saved/` `DerivedDataCache/` `Content/` `Plugins/` —— 由 `FPS_NetWork0` 自己的 `.gitignore` 负责，**该仓库只跟踪源码与配置，资产与插件不入版本控制**。
---

## 环境要求

- **Unreal Engine 5.8**（`EngineAssociation = "5.8"`）；
- **Visual Studio 2022**，含 "使用 C++ 的游戏开发" 工作负载与 Windows 10/11 SDK；
- **Windows 10/11**（工程仅验证过 Win64 + DX12 + SM6）；
- **Steam 客户端**，已登录（联机必需，`DefaultPlatformService=Steam`）；
- 磁盘：源码约 1 MB，但完整工程（含 `Intermediate` 编译缓存）实测约 **14.6 GB**。

启用的插件（`FPS_NetWork0.uproject`）：

| 插件 | 类型 | 用途 |
|---|---|---|
| `GameplayAbilities` | 引擎 | GAS 本体 |
| `GameplayTags` / `GameplayTasks` | 引擎 | GAS 依赖（见 Build.cs） |
| `EnhancedInput` | 引擎 | 输入系统 |
| `CommonUI` | 引擎 | UI 基建（`GameViewportClientClassName` 用的就是它） |
| `OnlineSubsystem` / `OnlineSubsystemSteam` | 引擎 | Steam 在线服务 |
| `SteamSockets` | 引擎 | UE5 的 Steam P2P 传输层（**必需**，见下） |
| `AnimationWarping` | 引擎 | 动画 |
| `ModelingToolsEditorMode` | 引擎（仅 Editor） | 建模工具 |
| `MultiplayerSessions` | **项目自带** | 会话管理 + 大厅菜单 |

`Source/FPS_NetWork0/FPS_NetWork0.Build.cs` 的公共依赖（15 个）：

```text
Core, CoreUObject, Engine, InputCore, EnhancedInput,
GameplayTags, GameplayTasks, GameplayAbilities, PhysicsCore,
Slate, UMG, SlateCore,
MultiplayerSessions, OnlineSubsystem, OnlineSubsystemSteam
```

---

## 本地启动

**1. 克隆（含子模块）**

```bash
git clone --recursive https://github.com/duan-fresh/FPS_GAS.git
```

若已克隆但漏了子模块：

```bash
cd FPS_GAS
git submodule update --init --recursive
```

**2. 生成工程文件**

关闭编辑器，右键 `FPS_NetWork0/FPS_NetWork0.uproject` → **Generate Visual Studio project files**。

> 若找不到 `.uproject` 右键菜单，说明 UE 5.8 未正确关联，用引擎目录下的 `UnrealVersionSelector.exe` 修复。

**3. 编译**

用 VS 打开 `FPS_NetWork0.sln`，配置选 **Development Editor | Win64**，编译 `FPS_NetWork0` 目标。

**4. 启动**

双击 `FPS_NetWork0/FPS_NetWork0.uproject`。首次打开若提示需重启以启用 `GameplayAbilities`，选允许。

**5. 配置 AI 技能链接（可选）**

```powershell
powershell -ExecutionPolicy Bypass -File .\link_ue_claude_skills_commands.ps1
```

脚本会把 `.agents\unreal-engine-skills\skills` 下的技能目录以 Junction 形式挂到 `.claude\skills`。注意脚本硬编码了 8 个技能名，其中 `ue-project-context`、`ue-data-assets-tables`、`ue-ai-navigation` 在本仓库中**不存在**，会输出 `Write-Warning` 跳过。

默认地图与启动地图均为 `/Game/Maps/Lobby`，`GameInstanceClass` 指向 `UFPSGameInstance`。

---

## 操作与联机测试

### 按键

| 按键 | 功能 |
|---|---|
| 鼠标左键 | 开火 |
| 鼠标右键 | 瞄准 |
| `E` | 切换武器 |
| `R` | 换弹 |
| `空格` | 跳跃 |
| `C` | 蹲下 |
| `G` | 扔烟雾弹 |

### 数值

- 玩家共 **150 血**（100 Health + 50 Shield）；
- 手枪：单发 **100** 伤害；
- 步枪：单发 **15** 伤害，另附加 **5 秒燃烧**（每 0.5 秒 3 点，共 30）；
- 地图中有旋转枪械模型可补充弹药，**只提供步枪弹药**。

### 联机步骤

1. 双方启动并登录 Steam，**把下载地区设为一致**；
2. 进入 `Lobby` 地图，选择 **Host** 或 **Join**；
3. 房主可设置玩家上限（默认 4）与房间类型标签（`Capture the Flag` / `Free For All` / `Teams`）；
4. **房主与客户端必须勾选同一房间类型**，否则永远匹配不到；
5. 两人以上进入后，房主按 **`Enter`** 开始游戏；
6. 右上角 **Quit** 退出。

> 只有 1 人时不会开局（提示人数不足）；对局中人数掉到 1 会触发结算。

## 仓库与协作规范

- `FPS_NetWork0` 有**独立 git 历史**（14 次提交，2026-07-18 起），远端是 `FPS_NetWork0.git`；
- `FPS_GAS` 是总仓库，通过 submodule **引用**它。因此：
  - 改 UE 代码 → 先在 `FPS_NetWork0/` 里提交并推送到 `FPS_NetWork0.git`，**再**回总仓库提交 submodule 指针；
  - 只推总仓库而不推子模块，会让指针悬空， `clone --recursive` 失败

## 第三方与许可

| 组件 | 来源 | 许可 |
|---|---|---|
| `Plugins/MultiplayerSessions` | Stephen Ulibarri 教程插件（*Unreal Engine 5 C++ Multiplayer Shooter*），已本地魔改 | 随教程，商用前需自行确认 |
| `.agents/unreal-engine-skills` | [quodsoler/unreal-engine-skills](https://github.com/quodsoler/unreal-engine-skills) | MIT |
| `Content/Downwash_Dust_FX` | 第三方下洗气流 / 扬尘特效包 | 需自行确认 |
| `Content/Fab` | Fab 商城下载内容 | 需自行确认 |

**分发或商用前，请自行核实上述资产的授权与再分发条款。** 引擎素材（Mannequin、ShooterTechDemoArea 等）另受 Unreal Engine EULA 约束。

`Plugins/MultiplayerSessions` 使用的 `SteamDevAppId=480` 是 Steam 官方测试 AppID（Spacewar），**仅供开发调试**，不能用于正式发行。
