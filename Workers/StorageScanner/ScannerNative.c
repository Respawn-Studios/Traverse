#include "ScannerNative.h"
#include <sys/attr.h>
#include <sys/stat.h>
#include <sys/mount.h>
#include <sys/resource.h>
#include <sys/unistd.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <CommonCrypto/CommonDigest.h>
#include <signal.h>
#include <mach/mach.h>
#include <pthread.h>
#include <pthread/qos.h>
#include <errno.h>
int b06_set_utility_qos(void) { qos_class_t observed;int priority=0;
    int status=pthread_set_qos_class_self_np(QOS_CLASS_UTILITY,0);
    if(!status)status=pthread_get_qos_class_np(pthread_self(),&observed,&priority);
    if(status){errno=status;return -1;}
    if(observed!=QOS_CLASS_UTILITY||priority!=0){errno=EINVAL;return -1;}
    return 0;
}
static volatile sig_atomic_t cancelled=0;
static void cancel_handler(int ignored) { (void)ignored; cancelled=1; }
void b06_install_cancellation(void) { struct sigaction a={0};a.sa_handler=cancel_handler;sigemptyset(&a.sa_mask);sigaction(SIGTERM,&a,0);sigaction(SIGINT,&a,0); }
int b06_cancelled(void) { return cancelled; }
int b06_resources(B06Resources *o) { struct rusage r;mach_task_basic_info_data_t i;mach_msg_type_number_t count=MACH_TASK_BASIC_INFO_COUNT;
    if(getrusage(RUSAGE_SELF,&r)||task_info(mach_task_self(),MACH_TASK_BASIC_INFO,(task_info_t)&i,&count)!=KERN_SUCCESS)return -1;
    o->current_rss=i.resident_size;o->peak_rss=r.ru_maxrss;o->user_ns=(uint64_t)r.ru_utime.tv_sec*1000000000+(uint64_t)r.ru_utime.tv_usec*1000;o->system_ns=(uint64_t)r.ru_stime.tv_sec*1000000000+(uint64_t)r.ru_stime.tv_usec*1000;return 0;
}
uint32_t b06_common_mask(void) { return ATTR_CMN_NAME|ATTR_CMN_DEVID|ATTR_CMN_OBJTYPE|ATTR_CMN_FLAGS|ATTR_CMN_FILEID|ATTR_CMN_ERROR|ATTR_CMN_RETURNED_ATTRS; }
uint32_t b06_directory_mask(void) { return ATTR_DIR_LINKCOUNT|ATTR_DIR_MOUNTSTATUS; }
uint32_t b06_file_mask(void) { return ATTR_FILE_LINKCOUNT|ATTR_FILE_TOTALSIZE|ATTR_FILE_ALLOCSIZE|ATTR_FILE_DATALENGTH|ATTR_FILE_DATAALLOCSIZE; }
static struct attrlist attrs(void) { struct attrlist a={0}; a.bitmapcount=ATTR_BIT_MAP_COUNT; a.commonattr=b06_common_mask(); a.dirattr=b06_directory_mask(); a.fileattr=b06_file_mask(); return a; }
int b06_policy_get(void) { return getiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,IOPOL_SCOPE_THREAD); }
int b06_policy_off(void) { return setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,IOPOL_SCOPE_THREAD,IOPOL_MATERIALIZE_DATALESS_FILES_OFF); }
int b06_policy_restore(int p) { return setiopolicy_np(IOPOL_TYPE_VFS_MATERIALIZE_DATALESS_FILES,IOPOL_SCOPE_THREAD,p); }
int b06_open_root(const char *p) { return open(p,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW_ANY); }
int b06_open_directory(int fd,const char *p) { return openat(fd,p,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW_ANY); }
static void from_stat(struct stat *s,B06Identity *o) { memset(o,0,sizeof(*o)); o->dev=(uint32_t)s->st_dev; o->ino=s->st_ino; o->nlink=s->st_nlink; o->flags=s->st_flags; o->mode=s->st_mode; o->mtime_sec=s->st_mtimespec.tv_sec;o->mtime_nsec=s->st_mtimespec.tv_nsec;o->ctime_sec=s->st_ctimespec.tv_sec;o->ctime_nsec=s->st_ctimespec.tv_nsec; }
int b06_identity(int fd,B06Identity *o) { struct stat s; struct statfs fs; if(fstat(fd,&s)||fstatfs(fd,&fs))return -1; from_stat(&s,o); o->fsid0=fs.f_fsid.val[0]; o->fsid1=fs.f_fsid.val[1]; o->local=!!(fs.f_flags&MNT_LOCAL); return 0; }
int b06_identity_at(int fd,const char *p,B06Identity *o) { struct stat s; if(fstatat(fd,p,&s,AT_SYMLINK_NOFOLLOW))return -1; from_stat(&s,o); return 0; }
int b06_bulk(int fd,void *b,size_t n) { struct attrlist a=attrs(); return getattrlistbulk(fd,&a,b,n,0); }
int b06_metadata(int fd,const char *p,void *b,size_t n) { struct attrlist a=attrs(); return getattrlistat(fd,p,&a,b,n,FSOPT_NOFOLLOW|FSOPT_NOFOLLOW_ANY|FSOPT_RESOLVE_BENEATH); }
void b06_sha256(const void *p,size_t n,uint8_t *o) { CC_SHA256(p,(CC_LONG)n,o); }

/* Public F_GETPATH captures a namespace spelling, not confinement or authority. */
int b06_root_path(int fd, char *output, size_t capacity) {
    if(capacity < 1024) { errno=EINVAL;return -1; }
    memset(output,0,capacity);
    if(fcntl(fd,F_GETPATH,output))return -1;
    if(!memchr(output,0,1024)||output[0]!='/'){errno=EINVAL;return -1;}
    return 0;
}

#include "ResultAuthority.c"
#include "StartupPhysical.c"
