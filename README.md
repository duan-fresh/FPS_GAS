# FPS_GAS

基于 **Unreal Engine 5.8** 和 C++ 开发的多人 FPS 学习原型，使用 **Gameplay Ability System（GAS）** 管理属性、伤害和技能，并通过 **Steam P2P** 实现联机。

> **项目状态：学习 / 个人原型**
>
> 本项目主要用于验证 GAS 接入、武器系统和多人联机流程，不是生产就绪系统，也不建议直接作为商业项目基础。
> 默认使用 Steam 测试 AppID `480`（Spacewar），仅供本地和好友联机调试。

---

## 功能概览

- 基于 GAS 的生命值、护盾、伤害和技能系统
- 先扣护盾、溢出伤害扣除生命值
- 支持伤害效果、持续伤害和重生属性重置
- 烟雾弹技能
- 手枪和步枪
- 开火、瞄准、换弹、切换武器和弹药补充
- 步枪燃烧持续伤害
- 连杀统计和特殊击杀提示
- Steam P2P 创建、搜索和加入房间
- UMG 血条、弹药、准星、计分板和提示 UI
- 本地玩家存档
- 使用 DataAsset 配置武器和特殊击杀数据

---

## 技术栈

- Unreal Engine 5.8
- C++
- Gameplay Ability System
- Enhanced Input
- UMG
- Online Subsystem Steam
- SteamSockets
- Git Submodule

---

## 项目结构

```text
FPS_GAS/
├── FPS_NetWork0/              UE 5.8 游戏工程
├── GameplayFrame/             UE 引擎行为验证记录
├── 记录AI过程/                 开发过程记录
├── .agents/                   Unreal Engine 辅助技能
└── README.md
```

UE 工程主要模块位于：

```text
FPS_NetWork0/Source/FPS_NetWork0/
├── AbilitySystem/             GAS、属性、技能和效果
├── Character/                 玩家角色
├── Combat/                    战斗和连杀逻辑
├── Data/                      DataAsset 和存档数据
├── Game/                      GameMode、GameState、GameInstance
├── Health/                    GAS 与 UI 的适配层
├── Player/                    PlayerState 和 PlayerController
├── UI/                        UMG C++ 基类
└── Weapon/                    武器系统
```

---

## 环境要求

- **Unreal Engine 5.8**；
- **Visual Studio 2022**，含 "使用 C++ 的游戏开发" 工作负载与 Windows 10/11 SDK；
- **Windows 10/11**；
- **Steam 客户端**，已登录（联机必需）；

联机测试时，所有玩家需要登录 Steam。

---

## 本地启动

### 1. 克隆仓库

```bash
git clone --recursive https://github.com/duan-fresh/FPS_GAS.git
cd FPS_GAS
```

如果仓库已经克隆但子模块未初始化：

```bash
git submodule update --init --recursive
```

### 2. 生成工程文件

关闭 Unreal Editor，右键打开：

```text
FPS_NetWork0/FPS_NetWork0.uproject
```

选择：

```text
Generate Visual Studio project files
```

如果右键菜单中没有该选项，请使用 Unreal Engine 目录下的 `UnrealVersionSelector.exe` 重新关联工程。

### 3. 编译

使用 Visual Studio 打开生成的解决方案，选择：

```text
Development Editor | Win64
```

然后编译 `FPS_NetWork0` 项目。

### 4. 启动

双击：

```text
FPS_NetWork0/FPS_NetWork0.uproject
```

首次打开时，如果 Unreal Editor 提示启用 GameplayAbilities 等插件，请允许并重启编辑器。

---

## 操作

| 按键 | 功能 |
|---|---|
| 鼠标左键 | 开火 |
| 鼠标右键 | 瞄准 |
| `E` | 切换武器 |
| `R` | 换弹 |
| `Space` | 跳跃 |
| `C` | 蹲下 |
| `G` | 投掷烟雾弹 |

---

## 游戏数值

- 玩家生命值：100
- 玩家护盾值：50
- 手枪：单发 100 点伤害
- 步枪：单发 15 点伤害
- 步枪命中后附加 5 秒燃烧效果
- 燃烧效果每 0.5 秒造成 3 点伤害
- 地图中的旋转枪械模型可用于补充弹药

---

## 联机测试

1. 所有玩家启动游戏并登录 Steam。
2. 进入 `Lobby` 地图。
3. 房主选择 `Host`，其他玩家选择 `Join`。
4. 设置玩家人数和房间类型。
5. 房主和客户端必须选择相同的房间类型。
6. 至少两名玩家进入房间后，房主按 `Enter` 开始游戏。

当前房间类型主要用于匹配过滤，不会改变实际玩法规则。

---

## 已知限制

- 当前没有自动化测试，只通过 PIE 和本地联机进行验证。
- 不支持 Dedicated Server。
- 不支持匹配队列、排位、反作弊和举报系统。
- 存档只保存在本机，不支持云同步。
- 房间类型不提供真正的好友权限控制。
- Steam P2P 联机依赖 Steam 客户端和测试 AppID `480`。
- 当前项目仍处于学习和原型阶段，网络安全性和系统完整性有限。

---

## Git Submodule 说明

`FPS_NetWork0` 是独立的 Git 子模块。

修改 UE 工程代码时：

1. 先在 `FPS_NetWork0` 子模块中提交并推送修改。
2. 再回到主仓库提交新的 submodule 指针。

```bash
cd FPS_NetWork0
git add .
git commit -m "Update gameplay code"
git push

cd ..
git add FPS_NetWork0
git commit -m "Update FPS_NetWork0 submodule"
git push
```

---

## 第三方内容与许可

项目包含以下第三方内容：

- `MultiplayerSessions`：基于 Stephen Ulibarri Unreal Engine 多人射击教程插件修改
- `.agents/unreal-engine-skills`：第三方 Unreal Engine AI辅助技能
- Fab 商店中的模型、材质和特效资源
- Unreal Engine 示例资源

分发或商业使用前，需确认相关插件、素材和 Unreal Engine 的授权及再分发条款。
