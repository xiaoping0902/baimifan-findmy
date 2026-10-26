# kfd 的通道与会话生命周期（本项目实况）

本文回答一个反复出现的误解：**kfd 不是"一直跑着的程序"，它是一次性的改装。**
下面写的是我们这个仓库里实际成立的事实，以及代码位置；不是对上游 kfd 的泛泛描述。

## 1. 一句话结论

`kopen` 跑一次（几秒），从此以后每次读内存都是**一个正常的系统调用**作用在
**被改坏的内核对象**上。内核里没有模块、没有线程、没有陌生代码；进程退出后
一切自动归零。

## 2. 时间轴（对照代码）

| 时刻 | 发生了什么 | 代码位置 |
|---|---|---|
| T0 App 启动 | 与 kfd 相关的东西一件都没跑，只有 UI | — |
| T1 用户点「启动内核」 | `mf_kopen(pages, method, 1, 1)`：唯一入口，防重入 | `MFKernel.mm` 的 `startWithPuafPages:completion:` |
| T1 内部 ① | `puaf_init` + `krkw_init` 布置 | `kfd/libkfd.h:162-163` |
| T1 内部 ② | `puaf_run` —— **漏洞只在这里触发一次** | `kfd/libkfd.h:290` |
| T1 内部 ③ | `krkw_init/run` 建读写通道，`info_run` 找内核算偏移 | `kfd/libkfd.h:325-336` |
| T2 内部 ④ | `puaf_cleanup(kfd)` —— **清痕，在 kopen 返回之前就完成** | `kfd/libkfd.h:338` → `kfd/libkfd/puaf.h:51` |
| T2 返回 | `mf_kopen` 记录耗时并置 `cleanup_done` | `MFKernelBridge.m` 的 `mf_kopen` |
| T4 游戏全程 | 每次读 → `mfpt_translate/mfpt_read` → `kread`（sem_open 后端） | `MFPageTable.m`、`MFReadBackend.mm` |
| T5 退出/停止 | `mf_kclose` → `kclose` → `krkw_free` + `puaf_free`，fd 与端口全部关闭 | `MFKernelBridge.m` 的 `mf_kclose` |

## 3. 我们的通道是哪个后端

`MFKernel.mm` 里 `mf_kopen` 的实参是 `kread_method = 1 (kread_sem_open)`、
`kwrite_method = 1 (kwrite_sem_open)`；`kfd/libkfd.h:250-251` 有断言把这两个绑成一对
（另一个 kqueue 后端在 iOS 16.3+ 已废弃）。

含义：读写靠的是**被重叠污染的命名信号量对象 + 普通 `sem_open`/`sem_post`**。
这正是"没有常驻代码也能读"的载体。

## 4. 与同类样本（欧易 2.0）的差别

| 维度 | 欧易 2.0 | 我们 |
|---|---|---|
| 内核里有无代码/线程 | 无 | 无 |
| 触发后清痕 | `km_cleanup_exploit_traces` 手动调 | `puaf_cleanup` 在 kopen 内部自动跑 |
| 读后端 | IOSurface（数组被改成 0x4000，一次 syscall 读一批） | sem_open（4 字节粒度，每次一个信号量操作） |
| 读取开销 | 低 | 较高，靠 4096 项 v2p 缓存与页表翻译缓存压次数 |
| 进程退出 | fd/port 关闭 → 通道消失 | 相同 |

**结论：生命周期机制完全同类；差距在读取吞吐，不在"要不要常驻"。**
想提高吞吐只能换后端（IOSurface 需自研，工程量与风险都高），不是改生命周期。

## 5. 三条硬约束（写死，别踩）

1. **`puaf_cleanup` 清理的是页表项伪装，不是被重叠的物理页。**
   物理页是通道本体，只有 `puaf_free` 才释放 —— 一释放读取立刻全断。
   看到「清理」两个字就想顺手 `puaf_free`，是错的。
2. **`puaf_cleanup` 只能发生一次。** 它把 `vm_map_entry` 的 links 与红黑树指针
   还原成正常形态；再调一次等于对着已经正常的结构做还原，会破坏状态。
3. **每次启动 App 都要重新触发。** 通道随进程存活，进程一没了就得重来；
   UI 上那个「启动内核」按钮就是为此存在的（`kernelInitialized` 防重入）。

## 6. 现场怎么核对（不靠注释）

被动状态文件 `/var/mobile/mf-debug/hud-state-*.json` 里有两个字段专门为这件事准备：

```json
"kernelInit":   { "cleanup": true, "openMs": 2100.0, "puafPages": 3072 },
"kernelWrites": { "count": 0, "bytes": 0 }
```

- `cleanup: true` + `openMs >= 0` → 这一轮确实走完了「触发 + 清痕」，不是只看 UI 文案；
- `kernelWrites.count` 应为 **0**：读取只走页表，正常配置下我们**不写内核**。
  拿不到 0 就说明有路径在写内核，必须查清是谁。

`scripts/hud_status.py` 已按这两条判据解释（`kernelCleanupDone` / `kernelWriteCount`），
任一不满足都会写进 `reasons`。
