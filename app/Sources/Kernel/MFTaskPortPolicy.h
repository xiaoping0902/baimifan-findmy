#ifndef MF_TASK_PORT_POLICY_H
#define MF_TASK_PORT_POLICY_H

static inline int mf_task_port_policy_allows(int caller_pid, int target_pid)
{
    return caller_pid > 0 && target_pid == caller_pid;
}

#endif
