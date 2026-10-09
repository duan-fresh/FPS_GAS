# UE 5.8 Actor / Component 销毁顺序与回调时机

> 整理日期：2026-09-30
> 引擎版本：UE 5.8（`C:\Program Files\Epic Games\UE_5.8`）
> 项目：`D:\Projects\UE_Projects\FPS_GAS\FPS_NetWork0`
>
> 本文所有行号均来自本机引擎源码实测，可逐条核对。
> 起因：存档重构时发现「宿主的 `PlayerState` 在 `EndPlay` 里读不到」，查证后推翻了两个直觉。

---

## 文件索引

引擎根目录 `C:\Program Files\Epic Games\UE_5.8\Engine\Source\`，下文用短名引用：

| 短名 | 相对路径 |
|---|---|
| `Actor.cpp` | `Runtime/Engine/Private/Actor.cpp` |
| `Actor.h` | `Runtime/Engine/Classes/GameFramework/Actor.h` |
| `ActorComponent.cpp` | `Runtime/Engine/Private/Components/ActorComponent.cpp` |
| `LevelActor.cpp` | `Runtime/Engine/Private/LevelActor.cpp` |
| `World.cpp` / `World.h` | `Runtime/Engine/Private/World.cpp`、`Runtime/Engine/Classes/Engine/World.h` |
| `Level.cpp` | `Runtime/Engine/Private/Level.cpp` |
| `Controller.cpp` | `Runtime/Engine/Private/Controller.cpp` |
| `PlayerController.cpp` | `Runtime/Engine/Private/PlayerController.cpp` |
| `PlayerState.cpp` | `Runtime/Engine/Private/PlayerState.cpp` |
| `GameMode.cpp` / `GameModeBase.cpp` | `Runtime/Engine/Private/GameMode.cpp`、`GameModeBase.cpp` |
| `UnrealEngine.cpp` | `Runtime/Engine/Private/UnrealEngine.cpp` |
| `GameEngine.cpp` | `Runtime/Engine/Private/GameEngine.cpp` |
| `GameInstance.cpp` | `Runtime/Engine/Private/GameInstance.cpp` |
| `LaunchEngineLoop.cpp` | `Runtime/Launch/Private/LaunchEngineLoop.cpp` |
| `PlayLevel.cpp` | `Editor/UnrealEd/Private/PlayLevel.cpp` |
| `GarbageCollection.cpp` | `Runtime/CoreUObject/Private/UObject/GarbageCollection.cpp` |
| `Obj.cpp` | `Runtime/CoreUObject/Private/UObject/Obj.cpp` |
| `EngineTypes.h` | `Runtime/Engine/Classes/Engine/EngineTypes.h` |

---

## 0. 为什么这个主题特别容易搞错

**Epic 只文档化了初始化顺序，没有文档化销毁顺序。**

`Actor.h:249-276` 那段著名的 Doxygen 注释（"Actor initialization has multiple steps, here's the order of important virtual functions"）从 `PostLoad` 一路列到 `BeginPlay` 就停了，销毁侧一个字都没有。

于是只能靠猜，而最常见的三个直觉**全是错的**：

| 直觉 | 实际 |
|---|---|
| `EndPlay` → `Destroyed` 是先后两步 | `EndPlay` **嵌在** `Destroyed()` 内部，是它的第一个动作 |
| `Destroyed` 之后就进 GC 了 | 中间还有 `RemoveActor` / `UnregisterAllComponents` / `MarkAsGarbage`，GC 是**另一趟** |
| `MarkAsGarbage` 完就开始析构 | 它只是打个标记，`BeginDestroy` 要等下一次 GC reachability |

---

## 1. 一句话总览

```
【创建】OnComponentCreated → OnRegister → OnConstruction → PreInitializeComponents
        → InitializeComponent → PostInitializeComponents → Actor::BeginPlay → Component::BeginPlay

【显式销毁 · 同一帧同步完成】
        Destroy()  ──►  UWorld::DestroyActor
            OnActorDestroyed.Broadcast
            Destroyed()
              ├─ RouteEndPlay(Destroyed)
              │    ├─ EndPlay(Destroyed)
              │    │    ├─ ReceiveEndPlay / OnEndPlay
              │    │    └─ 每个 Component::EndPlay      ← 顺序不确定（OwnedComponents 是 TSet）
              │    └─ UninitializeComponents()          ← 在 EndPlay 之后
              ├─ ReceiveDestroyed() / OnDestroyed.Broadcast
            Detach 子/父 Actor
            ClearComponentOverlaps() / SetOwner(nullptr)
            RemoveActor()                               ← 此时才离开 Level->Actors
            OnActorRemovedFromWorld.Broadcast
            UnregisterAllComponents()
              └─ 每个 Component::UnregisterComponent
                   DestroyPhysicsState → DestroyRenderState_Concurrent → OnUnregister
            MarkAsGarbage() ; MarkComponentsAsGarbage()
              └─ 每个 Component::OnComponentDestroyed(bDestroyingHierarchy = true) + MarkAsGarbage

【GC · 另一趟，可能隔很多帧】
        CollectGarbage → Reachability
            ConditionalBeginDestroy → AActor::BeginDestroy / UActorComponent::BeginDestroy
        → IncrementalDestroyGarbage
            IsReadyForFinishDestroy → ConditionalFinishDestroy → FinishDestroy
        → DestroyObjects → FreeUObjectIndex → ~UObject() → FreeUObject
```

---

## 2. 显式销毁：完整链条

### 2.1 `Destroy()` 是延迟的

`Actor.h:2320-2327` 的注释写得很明确：

> Destroy this actor. ... **Destruction is latent. It occurs at the end of the tick.**

`AActor::Destroy()` 本身只是个转发器（`Actor.cpp:5343-5359`），带 `IsPendingKillPending()` 幂等保护，最终调 `UWorld::DestroyActor`。

`UWorld::DestroyActor` 有两个重载：公开版 `LevelActor.cpp:819`，实现版 `LevelActor.cpp:839`。

`LevelActor.cpp:828-837` 的注释很关键：

> What this function does not do, but is handled via garbage collection instead, is remove references to this actor from all other actors, and kill the actor's resources.

**即：`DestroyActor` 不负责资源释放和引用清理，那是 GC 的事。**

### 2.2 `UWorld::DestroyActor` 内部步骤

| # | 行号 | 动作 |
|---|---|---|
| 1 | `LevelActor.cpp:857` | `IsPendingKillPending()` → 直接 return（防重复通知） |
| 2 | `LevelActor.cpp:912` | `FMarkActorIsBeingDestroyed`（置 `bActorIsBeingDestroyed`） |
| 3 | `LevelActor.cpp:921` | `IStreamingManager::NotifyActorDestroyed` |
| 4 | `LevelActor.cpp:923` | **`OnActorDestroyed.Broadcast(Actor)`**（UWorld 级委托） |
| 5 | `LevelActor.cpp:926` | **`Actor->Destroyed()`** ← 见 2.3 |
| 6 | `LevelActor.cpp:929-975` | Detach 所有 attached 子 Actor / 从父级 detach |
| 7 | `LevelActor.cpp:981` | `ClearComponentOverlaps()` |
| 8 | `LevelActor.cpp:984-987` | `SetOwner(nullptr)` |
| 9 | `LevelActor.cpp:989-1007` | `CreateReplicatedDestructionInfo`（无 DemoNetDriver 时） |
| 10 | `LevelActor.cpp:1012-1021` | 各 NetDriver `NotifyActorDestroyed` |
| 11 | **`LevelActor.cpp:1034`** | **`RemoveActor(Actor, ...)`** ← 见 2.4 |
| 12 | `LevelActor.cpp:1049` | **`OnActorRemovedFromWorld.Broadcast(Actor)`** |
| 13 | **`LevelActor.cpp:1052`** | **`Actor->UnregisterAllComponents()`** ← 见 3.2 |
| 14 | **`LevelActor.cpp:1055`** | **`Actor->MarkAsGarbage()`** |
| 15 | `LevelActor.cpp:1056` | `MarkPackageDirty()` |
| 16 | **`LevelActor.cpp:1057`** | **`MarkComponentsAsGarbage()`** ← 见 3.3 |
| 17 | `LevelActor.cpp:1060-1062` | 反注册所有 Actor/Component tick 函数 |

走到第 17 步，Actor **对象仍然存活**，只是被标记为 garbage。

### 2.3 `AActor::Destroyed()` 展开

`Actor.cpp:3311-3317`：

```cpp
void AActor::Destroyed()
{
	RouteEndPlay(EEndPlayReason::Destroyed);   // 3313  ← 第一件事
	ReceiveDestroyed();                        // 3315  蓝图 "Event Destroyed"
	OnDestroyed.Broadcast(this);               // 3316
}
```

`AActor::RouteEndPlay`（`Actor.cpp:3221-3257`）：

```cpp
if (bActorInitialized)                                            // 3223
{
	if (ActorHasBegunPlay == EActorBeginPlayState::HasBegunPlay)  // 3225
	{
		EndPlay(EndPlayReason);                                   // 3229
		ensureMsgf(ActorHasBegunPlay == HasNotBegunPlay,
			TEXT("EndPlay on %s failed. Make sure to call Super::EndPlay()..."), ...);  // 3230
	}
	if (EndPlayReason == EEndPlayReason::RemovedFromWorld) { /* 3234-3244 特例 */ }
	if (TimerHandle_LifeSpanExpired.IsValid()) { SetLifeSpan(0.f); }  // 3247-3250
}
UninitializeComponents();                                         // 3255  ← 在 EndPlay 之后
```

`AActor::EndPlay`（`Actor.cpp:3259-3286`）：

```cpp
if (ActorHasBegunPlay == EActorBeginPlayState::HasBegunPlay)
{
	ActorHasBegunPlay = EActorBeginPlayState::HasNotBegunPlay;   // 3265 先改状态再分发
	StopReplicatingActor(this, ...);                             // 3268
	ReceiveEndPlay(EndPlayReason);                               // 3271 蓝图 "Event End Play"
	OnEndPlay.Broadcast(this, EndPlayReason);                    // 3272
	TInlineComponentArray<UActorComponent*> Components;
	GetComponents(Components);                                   // 3275
	for (UActorComponent* Component : Components)
		if (Component->HasBegunPlay())
			Component->EndPlay(EndPlayReason);                   // 3281
}
```

### 2.4 四个反直觉的结论

**① `EndPlay` 是 `Destroyed()` 的第一步，不是它的前驱。**
两者是**嵌套调用**关系，都在 `DestroyActor` 的同一帧、同一调用栈里。

**② `EndPlay` 时 Actor 还在世界里。**
`RemoveActor()` 在 `:1034`，排在 `Destroyed()`（`:926`）之后。`GetOwner()` 也还有效（`SetOwner(nullptr)` 在 `:984`，更靠后）。此时 `GetAllActorsOfClass` 仍能找到它。

**③ `RemoveActor` 是"置空"不是"删除"。**
`World.cpp:2892` 是 `CheckLevel->Actors[ActorListIndex] = nullptr;`，**不是** `RemoveSwap`。所以 `Level->Actors` 会留空洞。另外 `AActor::BeginDestroy`（`Actor.cpp:889-894`）里那段 `Level->Actors.RemoveSingleSwap` 只在 `#if UE_WITH_REMOTE_OBJECT_HANDLE` 下编译（该宏默认 0），普通构建走不到。

**④ 只有"开始过"的 Actor 才有 `EndPlay`。**
`RouteEndPlay` 有两道闸：`bActorInitialized`（`:3223`）和 `ActorHasBegunPlay == HasBegunPlay`（`:3225`）。**`BeginPlay` 之前就被销毁的 Actor，`EndPlay` 根本不会调**。
这也解释了 `:3230` 那句 `ensureMsgf(... Super::EndPlay() ...)`——不调 Super，`ActorHasBegunPlay` 就不会复位。

---

## 3. Component：顺序不确定 + 正确清理钩子

### 3.1 组件遍历顺序**不确定**（重要）

`AActor::GetComponents()` 最终遍历 `OwnedComponents`，而它是 **`TSet`**：

```cpp
// Actor.h:4331
TSet<TObjectPtr<UActorComponent>> OwnedComponents;
```

`TSet` 的迭代顺序 = 哈希桶顺序，**不是创建顺序、不是注册顺序**，且随元素增删/重哈希变化。

**受影响的地方**：`AActor::EndPlay` 里的组件 `EndPlay`（`Actor.cpp:3277`）、`UnregisterAllComponents`（`Actor.cpp:5969`）、`MarkComponentsAsGarbage`（`Actor.cpp:3323`）。

**实践含义**：某个组件在 `EndPlay` 里要访问同一 Actor 上的另一个组件时，**不能假设对方的 `EndPlay` 已经/尚未执行**。

**要确定性顺序**：自己排序，或改用 `InstanceComponents`（`Actor.h:4340`，`TArray`，保序）/ `BlueprintCreatedComponents`（`Actor.h:4345`）。

### 3.2 组件销毁回调全序

```
Actor->Destroyed()                                   LevelActor.cpp:926
 ├─ RouteEndPlay(Destroyed)                          Actor.cpp:3313
 │   ├─ Actor::EndPlay(Destroyed)                    Actor.cpp:3259
 │   │   ├─ ReceiveEndPlay / OnEndPlay               Actor.cpp:3271-3272
 │   │   └─ 每个 Component::EndPlay                  Actor.cpp:3281
 │   │        ├─ StopReplicatingActorComponent       ActorComponent.cpp:1676
 │   │        ├─ ReceiveEndPlay（蓝图）              ActorComponent.cpp:1683
 │   │        └─ bHasBegunPlay = false               ActorComponent.cpp:1687
 │   └─ UninitializeComponents()                     Actor.cpp:3255
 │        └─ Component::UninitializeComponent        ActorComponent.cpp:1636
 ├─ ReceiveDestroyed() / OnDestroyed.Broadcast       Actor.cpp:3315-3316

 ... detach / owner / net 通知 ...

Actor->UnregisterAllComponents()                     LevelActor.cpp:1052
 └─ 每个 Component::UnregisterComponent              Actor.cpp:5973
      ├─ RegisterAllComponentTickFunctions(false)     ActorComponent.cpp:2147
      ├─ ExecuteUnregisterEvents()                    ActorComponent.cpp:2148
      │    ├─ DestroyPhysicsState()                   ActorComponent.cpp:2536
      │    ├─ DestroyRenderState_Concurrent()         ActorComponent.cpp:2542
      │    └─ OnUnregister()                          ActorComponent.cpp:2549
      └─ WorldPrivate = nullptr                       ActorComponent.cpp:2150

Actor->MarkComponentsAsGarbage()                     LevelActor.cpp:1057
 └─ 每个 Component: OnComponentDestroyed(true)        Actor.cpp:6330
                    MarkAsGarbage()                   Actor.cpp:6331

 ... 隔若干帧 GC ...

Component::BeginDestroy                              ActorComponent.cpp:1183-1226
```

注意 `UActorComponent::BeginDestroy`（`ActorComponent.cpp:1183-1226`）里**也有** `EndPlay` / `UninitializeComponent` 的调用，但都被 `bHasBegunPlay` / `bHasBeenInitialized` 标志挡住——正常路径上早就置 false 了，是给"跳过正常销毁流程"的场景兜底的。

### 3.3 `OnComponentDestroyed` 有两条不同分支

| 路径 | 位置 | `bDestroyingHierarchy` |
|---|---|---|
| **Actor 被销毁**，组件跟着走 | `AActor::MarkComponentsAsGarbage` → `Actor.cpp:6330` | **`true`** |
| **手动** `Component->DestroyComponent()` | `ActorComponent.cpp:2201` | **`false`** |

手动 `DestroyComponent()` 的完整顺序（`ActorComponent.cpp:2153-2205`）：

```cpp
bIsBeingDestroyed = true;                                     // 2161 防重入
if (bHasBegunPlay)       EndPlay(EEndPlayReason::Destroyed);  // 2163
if (bHasBeenInitialized) UninitializeComponent();             // 2169
if (IsRegistered())      UnregisterComponent();               // 2177
// 从 OwnedComponents / BlueprintCreatedComponents / InstanceComponents 移除
OnComponentDestroyed(false);                                  // 2201
MarkAsGarbage();                                              // 2204
```

**结论：想让自定义组件在"Actor 销毁"时做清理，正确位置是 `EndPlay()` 或 `OnComponentDestroyed()` override，而不是在 Actor 的 `BeginDestroy()` 里手动 `DestroyComponent()`。**

---

## 4. GC 阶段

### 4.1 `MarkAsGarbage` 只是打标记

`UObjectBaseUtility.h:207-216`：

```cpp
inline void MarkAsGarbage()
{
	check(!IsRooted());                                    // 已 Root 的对象不能标记
	AtomicallySetFlags(RF_MirroredGarbage);
	GUObjectArray.IndexToObject(InternalIndex)->SetGarbage();
	AtomicallyClearInternalFlags(EInternalObjectFlags::Async);
}
```

**毫不同步调用 `BeginDestroy`。** 之后要等下一次 reachability 分析 + purge。

### 4.2 一次 GC 内部的阶段顺序

| 阶段 | 位置 | 动作 |
|---|---|---|
| Reachability | `GarbageCollection.cpp:5836 / 6042 / 6109` | 标记可达；不可达对象进 `GUnreachableObjects` |
| **ConditionalBeginDestroy** | **`GarbageCollection.cpp:6318`** | → `Obj.cpp:1298-1370`：置 `RF_BeginDestroyed`(:1315) → **`BeginDestroy()`(:1325)** |
| **IsReadyForFinishDestroy** | `GarbageCollection.cpp:4970 / 5050` | 不 ready 的进 `GGCObjectsPendingDestruction`(:4984)，留到后续 pass 重试 |
| **ConditionalFinishDestroy** | `GarbageCollection.cpp:4974 / 5054` | → `Obj.cpp:1372`：置 `RF_FinishDestroyed`(:1377) → **`FinishDestroy()`(:1382)** |
| 门闩 | `GarbageCollection.cpp:5180` | `GObjFinishDestroyHasBeenRoutedToAllObjects = true` |
| **DestroyObjects** | `GarbageCollection.cpp:5199` | → `:921 FreeUObjectIndex` → **`:959 Object->~UObject()`** → `:960 FreeUObject` |

`AActor::BeginDestroy()`（`Actor.cpp:883-924`）在普通构建下**只做三件事**：远程对象句柄清理（宏包裹）、CSV 统计、编辑器元素销毁，然后 `Super::BeginDestroy()`。

**它不调 `EndPlay`，也不反注册组件。** 走到这里时 Actor 已经不在 world 里了。

### 4.3 `BeginDestroy` 和 `FinishDestroy` 可能跨很多帧

`GarbageCollection.cpp:4970-4986`：

```cpp
if (Object->IsReadyForFinishDestroy())
	Object->ConditionalFinishDestroy();
else
{
	// 常见于图形资源在等渲染线程的 release fence
	GGCObjectsPendingDestruction.Add(Object);   // 留到后续 GC pass 再审
	GGCObjectsPendingDestructionCount++;
}
```

`IsReadyForFinishDestroy()` 默认返回 true（`Object.h:368`），所以普通 Actor 两段通常在同一趟 GC 走完。但**不能假设**——带渲染资源的组件可能额外跨帧，`:5112` 那条 `"Spent more than %.2fs on routing FinishDestroy"` 警告就是为大对象准备的。

从 `DestroyActor` 到 `BeginDestroy` **没有任何强制同步**，可以是几帧甚至更久。

### 4.4 为什么不能在 `BeginDestroy` 里访问别的 Actor

1. **时机不可控**：距 `Destroy()` 可能隔很多帧，世界状态早已不同
2. **顺序任意**：GC 按 `GUnreachableObjects` 数组顺序逐个 `ConditionalBeginDestroy`（`:6309-6318`）
3. **对方可能已被真正释放**：`~UObject()` 已跑、内存已回收；`WeakObjectPtr` 也会因 `ResetSerialNumber`（`Obj.cpp:1385`）失效
4. **救不回来**：purge 阶段已过 reachability 分析，新增引用不会被重新标记为可达
5. **本对象自身也在被拆**：`UActorComponent::BeginDestroy` 里 `WorldPrivate = nullptr`（`ActorComponent.cpp:1206`）并 `RemoveOwnedComponent`（`:1211`）
6. **官方约定**：`LevelActor.cpp:828-837` 明说引用清理交给 GC，所以正确做法是在 `EndPlay` / `Destroyed` / `OnDestroyed` / `OnComponentDestroyed` 里做

---

## 5. `EEndPlayReason` 是谁传的

枚举定义 `EngineTypes.h:3668-3685`：

```cpp
namespace EEndPlayReason {
	enum Type : int {
		Destroyed,        // 显式销毁
		LevelTransition,  // 世界因换图被卸载
		EndPlayInEditor,  // PIE 结束
		RemovedFromWorld, // 所在关卡被流式卸载
		Quit,             // 应用退出
	};
}
```

`RouteEndPlay` 的全部调用点：

| 位置 | Reason | 场景 |
|---|---|---|
| `Actor.cpp:3313`（`AActor::Destroyed`） | `Destroyed` | **任何** `DestroyActor` |
| `World.cpp:6205`（`UWorld::EndPlay`） | 形参 | 世界级 EndPlay，reason 由调用方给 |
| `Level.cpp:3939`（`ULevel::RouteActorEndPlayForRemoveFromWorld`） | `RemovedFromWorld` | 关卡流式卸载 |
| `World.cpp:8766` | `LevelTransition` | Seamless Travel 中"不保留"的 actor **逐个**处理 |

`UWorld::EndPlay(EEndPlayReason)` 的调用点：

| 调用点 | Reason |
|---|---|
| `GameEngine.cpp:1370` | **`Quit`** |
| `UnrealEngine.cpp:16259` | **`LevelTransition`** |
| `PlayLevel.cpp:897` | **`EndPlayInEditor`** |

**注意**：`UWorld::EndPlay` **不产生** `RemovedFromWorld`，后者只由 `ULevel::RouteActorEndPlayForRemoveFromWorld` 逐 actor 产生。

`Actor.h:3568` 对 `Destroyed()` 的注释值得记住：

> Called when this actor is explicitly being destroyed during gameplay or in the editor, **not called during level streaming or gameplay ending**

即：批量拆世界时（`World->EndPlay`）Actor 只拿到 `EndPlay`，**不会**拿到 `Destroyed()`。

---

## 6. 四条真实路径的完整时序

### 6.1 ClientTravel / LoadMap

`UEngine::LoadMap`（`UnrealEngine.cpp:16078`）关键段：

```cpp
WorldContext.World()->BeginTearingDown();                       // 16183
ShutdownWorldNetDriver(WorldContext.World());                   // 16220 ← 拆网络早于拆 Actor

for (FLocalPlayerIterator It(...); It; ++It)
{
	if (It->PlayerController && It->PlayerController->GetWorld() == WorldContext.World())
	{
		if (It->PlayerController->GetPawn())
			WorldContext.World()->DestroyActor(It->PlayerController->GetPawn(), true);  // 16247
		WorldContext.World()->DestroyActor(It->PlayerController, true);                 // 16249 ← reason = Destroyed
		It->PlayerController = nullptr;                                                 // 16250
	}
	It->CleanupViewState();                                                             // 16255
}

WorldContext.World()->EndPlay(EEndPlayReason::LevelTransition);  // 16259 ← 剩下的 Actor
WorldContext.World()->CleanupWorld();                            // 16262

WorldContext.World()->RemoveFromRoot();                          // 16274
// 16277-16293 MarkObjectsPendingKill 遍历 Level / StreamingLevel
WorldContext.SetCurrentWorld(nullptr);                           // 16302 ← OnWorldChanged(old, nullptr)
WorldContext.OwningGameInstance->PreloadContentForURL(URL);      // 16339 ← GameInstance 被复用
// 16315 TrimMemory() → CollectGarbage（16729）旧世界对象真正释放

NewWorld->SetGameInstance(WorldContext.OwningGameInstance);      // 16504 ← 同一个 GI
WorldContext.SetCurrentWorld(NewWorld);                          // 16508 ← OnWorldChanged(nullptr, new)
WorldContext.World()->SetGameMode(URL);                          // 16549
// 16642-16652 每个 LocalPlayer SpawnPlayActor（新 PC）
WorldContext.World()->BeginPlay();                               // 16661
WorldContext.OwningGameInstance->LoadComplete(...);              // 16697
```

**关键点**：

- **`LevelTransition` 从来不会落到 `PlayerController` 头上** —— PC 在 `:16249` 就被 `DestroyActor` 掉了，它拿到的是 `Destroyed`
- `:16250` 把 `Player->PlayerController` 置空，所以到 `:16259` 时本机玩家已经没有 PC 了
- **`GameInstance` 不 Shutdown**，只 `PreloadContentForURL` + `LoadComplete`
- **`:16302`～`:16508` 之间 `GameInstance->WorldContext == nullptr`**（`UGameInstance::OnWorldChanged` 在 NewWorld 为 null 时置空，`GameInstance.cpp:615`）——这是个"无世界窗口"
- `OnWorldChanged` 在 `LoadMap` 里触发**两次**（`:16302` 和 `:16508`），源头是 `FWorldContext::SetCurrentWorld`（`UnrealEngine.cpp:1670`）

### 6.2 ServerTravel

`UWorld::ServerTravel`（`World.cpp:9525`）→ `AGameModeBase::ProcessServerTravel`（`GameModeBase.cpp:477-537`）：

```cpp
StartToLeaveMap();                                        // 480
APlayerController* LocalPlayer = ProcessClientTravel(URLMod, bSeamless, bAbsolute);  // 515
World->NextURL = URLMod;                                  // 517
// NextSwitchCountdown = 0（非无缝）
```

`AGameModeBase::ProcessClientTravel`（`GameModeBase.cpp:393-435`）：

```cpp
for (FConstPlayerControllerIterator Iterator = GetWorld()->GetPlayerControllerIterator(); Iterator; ++Iterator)
{
	if (APlayerController* PC = Iterator->Get())
	{
		if (Cast<UNetConnection>(PC->Player) != nullptr)
			PC->ClientTravel(ClientUrl, TRAVEL_Relative, bSeamless);   // 423 远程玩家
		else
			PC->PreClientTravel(FURL, ..., bSeamless);                 // 429 本地玩家（宿主自己）
	}
}
```

宿主下一帧走 `UEngine::TickWorldTravel`（`UnrealEngine.cpp:15955`）→ `Browse` → `LoadMap`，**与 6.1 完全相同的拆除流程**。

**差异**：ServerTravel 先给每个远程 PC 发 `ClientTravel` RPC 让他们"自愿先走"；真正强拆连接是宿主 `LoadMap` 里的 `:16220 ShutdownWorldNetDriver`。宿主是 listen server，`LoadMap` 末尾 `:16564-16566` 会重新 `Listen(URL)`。

**注意**：`ServerTravel` 不带 `?listen` 时，其余客户端会被断开，各自走自己的断线/换图路径。

### 6.3 进程退出（QuitGame / Alt+F4）

触发：`UKismetSystemLibrary::QuitGame` → `TargetPC->ConsoleCommand("quit")`；`UGameEngine::Exec` 捕获 QUIT（`GameEngine.cpp:1527`）→ `HandleExitCommand` → `FPlatformMisc::RequestExit`。Alt+F4 / 关窗走 `GameEngine.cpp:1811-1815`。

`FEngineLoop::Exit`（`LaunchEngineLoop.cpp:4987`）：

```
5065  GEngine->PreExit()
5123  AppPreExit()          → FCoreDelegates::OnPreExit（6931）/ OnExit（6940）
5138  ShutdownRenderingThread()
```

`UGameEngine::PreExit()`（`GameEngine.cpp:1338-1394`），**对 `WorldList` 每个 world 循环**：

```cpp
World->BeginTearingDown();                                // 1355
CancelPending(World);                                     // 1358
ShutdownWorldNetDriver(World);                            // 1361
World->bIsLevelStreamingFrozen = false;                   // 1364
World->SetShouldForceUnloadStreamingLevels(true);         // 1365
World->FlushLevelStreaming(Visibility);                   // 1368
World->EndPlay(EEndPlayReason::Quit);                     // 1370 ★ 所有 Actor RouteEndPlay(Quit)
if (World->GetGameInstance() != nullptr)
	World->GetGameInstance()->Shutdown();                 // 1374 ★
World->CleanupWorld();                                    // 1377
...
Super::PreExit();                                         // 1393 → OnEnginePreExit（UnrealEngine.cpp:2709）
```

**顺序确认：`World->EndPlay(Quit)` 比 `GameInstance::Shutdown()` 早。**

`UGameInstance::Shutdown()`（`GameInstance.cpp:147-178`）：

```cpp
ReceiveShutdown();                                                     // 149 蓝图事件
if (OnlineSession) { ClearOnlineDelegates(); OnlineSession = nullptr; }// 151-155
for (int32 i = LocalPlayers.Num() - 1; i >= 0; --i)
	RemoveLocalPlayer(LocalPlayers[i]);                                // 157-164
		// 内部：PC->Destroy(true)  GameInstance.cpp:1003
SubsystemCollection.Deinitialize();                                    // 167
WorldContext = nullptr;                                                // 177 ← 之后 GI 摸不到世界
```

**注意**：`RemoveLocalPlayer` 会 `PC->Destroy(true)`（`:1003`），但这次 `Destroyed()` 里的 `RouteEndPlay` 会被 `ActorHasBegunPlay` 闸门挡掉——因为 `:1370` 的 `EndPlay(Quit)` 已经把标志复位了。**所以 PC 的 `EndPlay` 只会触发一次。**

### 6.4 PIE Stop

触发：`UEditorEngine::RequestEndPlayMap()`（`PlayLevel.cpp:1400`）只置位；下一帧 `UEditorEngine::Tick`（`EditorEngine.cpp:2505-2508`）调 `EndPlayMap()`。

`UEditorEngine::EndPlayMap()`（`PlayLevel.cpp:224`）→ 对每个 PIE world 调 **`TeardownPlaySession`（`:344`）**。

`UEditorEngine::TeardownPlaySession`（`PlayLevel.cpp:721-962`）：

```cpp
PlayWorld->BeginTearingDown();                                            // 725
// 注释原文：This is done in the GameEngine path in UEngine::LoadMap.
//          But since PIE is just shutting down, and not loading a new map,
//          we need to do it manually here for now.
for (FLocalPlayerIterator It(GEngine, PlayWorld); It; ++It)               // 796
{
	if (It->PlayerController)
	{
		if (It->PlayerController->GetPawn())
			PlayWorld->DestroyActor(It->PlayerController->GetPawn(), true);  // 802
		PlayWorld->DestroyActor(It->PlayerController, true);                 // 804 ← reason = Destroyed
		It->PlayerController = NULL;                                         // 805
	}
}
PlayWorld->FlushLevelStreaming();                                          // 849
PlayWorld->EndPlay(EEndPlayReason::EndPlayInEditor);                       // 897
PieWorldContext.OwningGameInstance->Shutdown();                            // 899
PlayWorld->CleanupWorld();                                                 // 912
PlayWorld->RemoveFromRoot();                                               // 915
```

`EndPlayMap` 之后：`:359 ShutdownWorldNetDriver`、`:484 GI->MarkAsGarbage()`、`:502 CollectGarbage`。

PIE 的 `UGameInstance` 是**独立的**（`PlayLevel.cpp:3007` `NewObject<UGameInstance>(this, GameInstanceClass)` + `AddToRoot()`），随 PIE 结束被标记回收。

### 6.5 四条路径对比

| | LoadMap（ClientTravel） | ServerTravel（宿主侧） | 进程退出 | PIE Stop |
|---|---|---|---|---|
| `ShutdownWorldNetDriver` 位置 | **最早**（16220） | 同 LoadMap | 早（1361） | **最晚**（PlayLevel.cpp:359） |
| PC 怎么死 | `DestroyActor`（16249） | 同 LoadMap | `World->EndPlay(Quit)`（1370）后由 `GI->Shutdown` 里 `Destroy(true)` | `DestroyActor`（804） |
| PC 的 `EndPlayReason` | `Destroyed` | `Destroyed` | **`Quit`** | `Destroyed` |
| 其余 Actor 的 reason | `LevelTransition` | `LevelTransition` | `Quit` | `EndPlayInEditor` |
| `GameInstance::Shutdown` | ❌ 不调 | ❌ 不调 | ✅ 1374 | ✅ 899 |
| GI 是否复用 | ✅ 跨图复用 | ✅ | ❌ 进程结束 | ❌ PIE 独立 |

---

## 7. `PlayerState` 有效性：一个会咬人的路径差异

**这一段是本次查证的核心发现。**

`AController::Destroyed()`（`Controller.cpp:595-612`）：

```cpp
void AController::Destroyed()
{
	if (GetLocalRole() == ROLE_Authority && PlayerState != NULL)   // 597
	{
		AGameModeBase* const GameMode = GetWorld()->GetAuthGameMode();
		if (GameMode)
		{
			GameMode->Logout(this);        // 603
		}
		CleanupPlayerState();              // 606  ← 这里之后 PlayerState 变 nullptr
	}
	UnPossess();                           // 609
	GetWorld()->RemoveController(this);    // 610
	Super::Destroyed();                    // 611  → RouteEndPlay(Destroyed) → EndPlay
}
```

`Logout` 在整个引擎运行时里**只有一个调用点**：`Controller.cpp:603`。所以 `Logout` / `CleanupPlayerState` 只在 PC 走 `Destroyed()` 时执行。

于是 `EndPlay` 里 `GetPlayerState()` 是否有效，**取决于路径**：

| 路径 | `EndPlay` 来源 | `PlayerState` |
|---|---|---|
| **ClientTravel / ServerTravel** | `UnrealEngine.cpp:16249` 先 `DestroyActor(PC)` → `Destroyed()` → `Logout`+`CleanupPlayerState` → 再 `RouteEndPlay(Destroyed)` | **宿主**（`ROLE_Authority`）→ **`nullptr`**<br>**远程客户端**（AutonomousProxy）→ **还有效**（`:597` 的 authority 判断跳过整段） |
| **PIE Stop** | `PlayLevel.cpp:804` 同样先 `DestroyActor(PC)` | 同上 |
| **进程退出 Quit** | `GameEngine.cpp:1370` 的 `World->EndPlay(Quit)` **直接派发**；`GI->Shutdown()`(:1374) 才销毁 PC | **还有效**（`Logout`/`CleanupPlayerState` 都还没跑） |

**这张表意味着**：`EndPlay` 里读 `PlayerState` 的代码会在**客户端能跑通、宿主在换图时静默失败**——而且不报错，极难定位。

**唯一"能安全读到战绩"的销毁期回调是 `AGameModeBase::Logout`**：
`AGameMode::Logout`（`GameMode.cpp:120-130`）里 `AddInactivePlayer(PC->PlayerState, PC)`（`:126`）——此时 `PlayerState` **一定**有效（`CleanupPlayerState` 在 `:606`，排在 `:603` 之后）。
但它**仅服务端**，且 **Quit 路径根本不经过它**，所以不能作为唯一依靠。

**实践结论**：销毁期不要依赖 `PlayerState`。需要在离开时保留的数据，应该在游戏进行中就渐进式地同步到某个跨世界存活的对象（如 `GameInstance`）上。

---

## 8. 回调速查表

### 创建侧（`Actor.h:249-276` 有官方文档）

| 回调 | 时机 | 备注 |
|---|---|---|
| `UObject::PostLoad` | 关卡里摆好的 Actor 反序列化后 | 新 spawn 的不调 |
| `UActorComponent::OnComponentCreated` | 原生组件创建时 | 关卡里存的组件不调 |
| `AActor::PreRegisterAllComponents` | 组件即将注册进场景 | |
| `UActorComponent::RegisterComponent` / `OnRegister` | 建立渲染/物理表现 | 可能跨多帧 |
| `AActor::PostRegisterAllComponents` | 所有组件注册完毕 | 所有初始化路径的最后一步 |
| `AActor::PostActorCreated` | 仅 spawn 的 Actor | |
| `AActor::OnConstruction` | 构造脚本之后 | 编辑器改蓝图会重跑 |
| `AActor::PreInitializeComponents` | 组件 Initialize 之前 | |
| `UActorComponent::Activate` | `bAutoActivate` 时 | |
| `UActorComponent::InitializeComponent` | `bWantsInitializeComponent` 时 | 每个 session 一次 |
| `AActor::PostInitializeComponents` | 组件都初始化完 | 置 `bActorInitialized` |
| `AActor::BeginPlay` | 世界开始 tick | 网络/子 Actor 会延后 |
| `UActorComponent::BeginPlay` | 紧跟 Actor 的 `BeginPlay` | |

### 销毁侧（**无官方文档**，以下全部来自 5.8 源码）

| 回调 | 触发点 | 此时什么还有效 |
|---|---|---|
| `AGameModeBase::Logout(Controller)` | `Controller.cpp:603` | PlayerState **有效**（唯一可靠的读取点，仅服务端） |
| `UActorComponent::EndPlay` | `Actor.cpp:3281` | 组件还注册着 |
| `AActor::EndPlay` / `ReceiveEndPlay` / `OnEndPlay` | `Actor.cpp:3259-3284` | World 有效；**PlayerState 因路径而异**（见 §7） |
| `UActorComponent::UninitializeComponent` | `Actor.cpp:3255` | 同上 |
| `AActor::Destroyed` / `ReceiveDestroyed` / `OnDestroyed` | `Actor.cpp:3311-3317` | 组件未反注册、尚未 `RemoveActor` |
| `UWorld::OnActorDestroyed` | `LevelActor.cpp:923` | Actor 完整 |
| `UWorld::OnActorRemovedFromWorld` | `LevelActor.cpp:1049` | 已 `RemoveActor` |
| `UActorComponent::OnUnregister` | `ActorComponent.cpp:2549` | Actor 已离开 Level |
| `UActorComponent::OnComponentDestroyed` | `Actor.cpp:6330` / `ActorComponent.cpp:2201` | `bDestroyingHierarchy` 区分两条路径 |
| `AActor::BeginDestroy` | GC pass（`GarbageCollection.cpp:6318`） | **已不在 world，别的 Actor 可能已回收** |
| `AActor::IsReadyForFinishDestroy` | `GarbageCollection.cpp:4970` | 返回 false 就留到下趟 |
| `AActor::FinishDestroy` | `GarbageCollection.cpp:4974` | 内存即将释放 |
| `UWorld::OnWorldBeginTearDown` | `World.cpp:6150` | 拆世界刚开始 |
| `UGameInstance::Shutdown` | `GameEngine.cpp:1374` / `PlayLevel.cpp:899` | World 已 `EndPlay`、未 `CleanupWorld` |
| `FWorldDelegates::OnWorldCleanup` | `World.cpp:6324` | **在 `GI::Shutdown` 之后** |
| `FCoreDelegates::OnEnginePreExit` | `UnrealEngine.cpp:2709` | 更晚 |
| `FCoreDelegates::OnPreExit` | `LaunchEngineLoop.cpp:6931` | 最晚 |

### 陷阱汇总

| 事项 | 说明 |
|---|---|
| 组件遍历顺序 | `OwnedComponents` 是 `TSet`，**不确定** |
| `EndPlay` 不一定被调 | `BeginPlay` 之前销毁的 Actor 没有 `EndPlay` |
| `EndPlayReason` 过滤 | 换图时 PC 拿 `Destroyed` 不是 `LevelTransition`；只认 `LevelTransition` 会漏掉主路径 |
| `PlayerState` | 销毁期有效性因路径而异，别依赖 |
| `BeginDestroy` | GC 阶段，不能访问其他 Actor；清理逻辑放这里太晚 |
| `UWorld::EndPlay` 的 reason | 由调用方决定，**不会**产生 `RemovedFromWorld` |
| GI 无世界窗口 | LoadMap 的 `:16302`～`:16508` 之间 `GameInstance->WorldContext == nullptr` |
| `SetPause` | listen server 上会冻结所有客户端，且停掉 `AGameMode::Tick`（判胜靠它轮询） |

---

## 9. 本项目中的实例

### 9.1 `AFPS_Controller::EndPlay`（存档重构引入）

`Source/FPS_NetWork0/Private/Player/FPS_Controller.cpp`：

```cpp
void AFPS_Controller::EndPlay(const EEndPlayReason::Type EndPlayReason)
{
	if (IsLocalController())
	{
		UWorld* World = GetWorld();
		if (UFPSGameInstance* FPSGameInstance = World ? Cast<UFPSGameInstance>(World->GetGameInstance()) : nullptr)
		{
			FPSGameInstance->SaveProfileNow();   // 只写盘，不读 PlayerState
		}
	}
	Super::EndPlay(EndPlayReason);
}
```

设计要点（都是被 §7 那张表逼出来的）：

- **只写盘，绝不在 `EndPlay` 里读 `PlayerState`** —— 因为它在不同路径下时有时无
- **不按 `EndPlayReason` 过滤** —— 三条主路径的 reason 都不含 `LevelTransition`
- 本局数据由 `AFPSPlayerState::PushProgressToLocalProfile()` 在**每次击杀/刷新连杀时**渐进式合并进 `GameInstance` 内存，所以任何时刻落盘都是最新值
- 这里**不做 `Wins++`** —— 胜场只在服务端判胜时 +1，重复写盘幂等

三条冗余写盘点：`AFPS_Controller::EndPlay` → `UFPSGameInstance::Shutdown()` → （显式的）`RequestLeaveMatch`。

### 9.2 `AFPSCharacter::BeginDestroy` —— **错误位置的清理逻辑**

`Source/FPS_NetWork0/Private/Character/FPSCharacter.cpp:117-122`：

```cpp
void AFPSCharacter::BeginDestroy()
{
	Super::BeginDestroy();
	if (!IsValid(CombatComponent)) return ;
	CombatComponent->DestroyComponent();
}
```

三个问题：

1. **时机太晚**：走到 `BeginDestroy` 时 `DestroyActor` 早已跑完，组件在 `LevelActor.cpp:1052` 就被 `UnregisterAllComponents()` 反注册过，Actor 也已 `MarkAsGarbage()`。这行多半是空转。
2. **阶段不安全**：`BeginDestroy` 是 GC 阶段，访问其他对象顺序不确定（见 §4.4）。
3. **会被反复执行**：`FPSGameMode.cpp:40-41` 的 `Character->Destroy()` 触发的是**重生**，不是生命周期结束——每次死亡都走一遍。

**正确做法**：改成 `UCombatComponent::EndPlay()` 或 `OnComponentDestroyed()` override（见 §3.3），或者直接依赖组件自己的销毁流程。

---

## 10. 一句话实践准则

> **要做游戏逻辑清理 / 存档 / 解绑委托 → `EndPlay` 或 `Destroyed` / `OnDestroyed` / `OnComponentDestroyed`。**
> **绝不要放 `BeginDestroy`（GC 阶段，太晚且不安全）。**
> **销毁期不要依赖其他 Actor / PlayerState / 组件顺序 —— 把需要的数据提前搬到一个跨世界存活的对象上。**
