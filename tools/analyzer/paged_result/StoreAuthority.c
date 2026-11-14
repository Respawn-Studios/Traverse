#include "StoreAuthority.h"
#include <sys/file.h>
#include <sys/stat.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <errno.h>
#include <spawn.h>
#include <sys/wait.h>
#include <sys/resource.h>
#include <stdio.h>
#include <signal.h>
#include <sqlite3.h>
#include <stdatomic.h>

static _Atomic uint64_t sql_statements,sql_commits,sql_ns,sql_commit_ns;
static int sql_profile(unsigned event,void *context,void *statement,void *elapsed) {
    (void)context;
    if (event!=SQLITE_TRACE_PROFILE || !elapsed) return 0;
    uint64_t ns=*(sqlite3_uint64*)elapsed;
    atomic_fetch_add_explicit(&sql_statements,1,memory_order_relaxed);
    atomic_fetch_add_explicit(&sql_ns,ns,memory_order_relaxed);
    const char *sql=sqlite3_sql(statement);
    if (sql && !strncmp(sql,"COMMIT",6)) {
        atomic_fetch_add_explicit(&sql_commits,1,memory_order_relaxed);
        atomic_fetch_add_explicit(&sql_commit_ns,ns,memory_order_relaxed);
    }
    return 0;
}
int b06_sql_profile(void *database) {return sqlite3_trace_v2(database,SQLITE_TRACE_PROFILE,sql_profile,NULL);}
void b06_sql_stats(B06SQLStats *result) {
    result->statements=atomic_load_explicit(&sql_statements,memory_order_relaxed);
    result->commits=atomic_load_explicit(&sql_commits,memory_order_relaxed);
    result->profile_ns=atomic_load_explicit(&sql_ns,memory_order_relaxed);
    result->commit_ns=atomic_load_explicit(&sql_commit_ns,memory_order_relaxed);
}

static int regular_private(struct stat *value) {
    return S_ISREG(value->st_mode) && value->st_nlink == 1 &&
        value->st_uid == geteuid() && (value->st_mode & 0777) == 0600;
}
static int same(struct stat *a, struct stat *b) {
    return a->st_dev == b->st_dev && a->st_ino == b->st_ino;
}
int b06_store_check(const char *path, int parent_fd, int database_fd, int lease_fd) {
    struct stat parent, current_parent, database, current_database, lease, current_lease;
    char folder[1024];
    size_t length = strnlen(path, sizeof(folder));
    const char suffix[] = "/result.sqlite";
    if (length >= sizeof(folder) || length <= sizeof(suffix)-1 ||
        strcmp(path + length - (sizeof(suffix)-1), suffix)) { errno = EINVAL; return -1; }
    memcpy(folder, path, length-(sizeof(suffix)-1));
    folder[length-(sizeof(suffix)-1)] = 0;
    if (fstat(parent_fd,&parent) || !S_ISDIR(parent.st_mode) ||
        parent.st_uid != geteuid() || (parent.st_mode & 0777) != 0700) { errno=EPERM;return -1; }
    int fresh = b06_open_root(folder);
    if (fresh < 0) return -1;
    int result = fstat(fresh,&current_parent); close(fresh);
    if (result || !same(&parent,&current_parent)) { errno=ESTALE;return -1; }
    if (fstat(database_fd,&database) || !regular_private(&database) ||
        fstatat(parent_fd,"result.sqlite",&current_database,AT_SYMLINK_NOFOLLOW) ||
        !regular_private(&current_database) || !same(&database,&current_database)) { errno=ESTALE;return -1; }
    if (fstat(lease_fd,&lease) || !regular_private(&lease) ||
        fstatat(parent_fd,"owner.lock",&current_lease,AT_SYMLINK_NOFOLLOW) ||
        !regular_private(&current_lease) || !same(&lease,&current_lease) ||
        flock(lease_fd,LOCK_EX|LOCK_NB)) { errno=ESTALE;return -1; }
    const char *sidecars[]={"result.sqlite-journal","result.sqlite-wal","result.sqlite-shm"};
    uint64_t store_bytes=(uint64_t)database.st_size;
    if (database.st_size<0 || store_bytes>33554432) {errno=EFBIG;return -1;}
    for (unsigned i=0;i<sizeof(sidecars)/sizeof(sidecars[0]);i++) {
        struct stat value;
        if (fstatat(parent_fd,sidecars[i],&value,AT_SYMLINK_NOFOLLOW)) {
            if (errno==ENOENT) continue;
            return -1;
        }
        if (!regular_private(&value)) {errno=ESTALE;return -1;}
        if (value.st_size<0 || (uint64_t)value.st_size>33554432-store_bytes) {errno=EFBIG;return -1;}
        store_bytes+=(uint64_t)value.st_size;
    }
    if (store_bytes>33554432) {errno=EFBIG;return -1;}
    return 0;
}

/* Explicit descriptor handoff; no shell, inherited environment or sibling job.
 * The parent holds fd3 source authority and fd4/fd5/fd6 store authority. */
int b06_paged_spawn(const char *binary,const char *store,const char *session,
                    uint64_t dev,uint64_t ino,int *pid,int *output,int *error) {
    int out[2]={-1,-1},err[2]={-1,-1},copies[4]={-1,-1,-1,-1};
    int count=store ? 4:1,code=-1;
    if (pipe(out) || pipe(err)) goto fail;
    for (int i=0;i<2;i++) {
        int descriptor=i ? err[0]:out[0];int flags=fcntl(descriptor,F_GETFL);
        if (flags<0 || fcntl(descriptor,F_SETFL,flags|O_NONBLOCK)) goto fail;
    }
    for (int i=0;i<count;i++) {
        copies[i]=fcntl(3+i,F_DUPFD_CLOEXEC,32);
        if (copies[i]<0) goto fail;
    }
    posix_spawn_file_actions_t actions;
    posix_spawnattr_t attrs;
    if (posix_spawn_file_actions_init(&actions)) goto fail;
    if (posix_spawnattr_init(&attrs)) {posix_spawn_file_actions_destroy(&actions);goto fail;}
    code=posix_spawn_file_actions_adddup2(&actions,out[1],STDOUT_FILENO);
    if (!code) code=posix_spawn_file_actions_adddup2(&actions,err[1],STDERR_FILENO);
    if (!code) code=posix_spawn_file_actions_addopen(&actions,STDIN_FILENO,"/dev/null",O_RDONLY,0);
    for (int i=0;i<count && !code;i++) code=posix_spawn_file_actions_adddup2(&actions,copies[i],3+i);
    sigset_t mask,defaults;sigemptyset(&mask);sigemptyset(&defaults);
    sigaddset(&defaults,SIGTERM);sigaddset(&defaults,SIGINT);
    if (!code) code=posix_spawnattr_setsigmask(&attrs,&mask);
    if (!code) code=posix_spawnattr_setsigdefault(&attrs,&defaults);
    if (!code) code=posix_spawnattr_setflags(&attrs,POSIX_SPAWN_CLOEXEC_DEFAULT|POSIX_SPAWN_SETSIGMASK|POSIX_SPAWN_SETSIGDEF);
    char device[32],inode[32];
    snprintf(device,sizeof(device),"%llu",(unsigned long long)dev);
    snprintf(inode,sizeof(inode),"%llu",(unsigned long long)ino);
    char *normal[]={(char*)binary,"--root-fd","3","--expected-dev",device,"--expected-ino",inode,"--session",(char*)session,NULL};
    char *stored[]={(char*)binary,"--qualification-store",(char*)store,"--root-fd","3","--expected-dev",device,"--expected-ino",inode,"--session",(char*)session,NULL};
    char *environment[]={"LANG=C","LC_ALL=C",NULL};
    pid_t child=-1;
    if (!code) code=posix_spawn(&child,binary,&actions,&attrs,store ? stored:normal,environment);
    posix_spawnattr_destroy(&attrs);posix_spawn_file_actions_destroy(&actions);
    if (code) {errno=code;goto fail;}
    close(out[1]);out[1]=-1;close(err[1]);err[1]=-1;
    for (int i=0;i<count;i++) {close(copies[i]);copies[i]=-1;}
    *pid=child;*output=out[0];*error=err[0];return 0;
fail:
    for (int i=0;i<2;i++) {if(out[i]>=0)close(out[i]);if(err[i]>=0)close(err[i]);}
    for (int i=0;i<4;i++) if(copies[i]>=0)close(copies[i]);
    return -1;
}
int b06_paged_wait(int pid,int *exit_code,uint64_t *peak_bytes) {
    int status=0;struct rusage usage;
    pid_t value=wait4(pid,&status,WNOHANG,&usage);
    if (value<0) return errno==EINTR ? 0:-1;
    if (!value) return 0;
    *exit_code=WIFEXITED(status) ? WEXITSTATUS(status):128+WTERMSIG(status);
    *peak_bytes=(uint64_t)usage.ru_maxrss;return 1;
}
