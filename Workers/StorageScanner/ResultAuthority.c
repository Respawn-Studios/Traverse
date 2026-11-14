/* Temporary analysis stores only. Never used for file-operation history.
 * A child pins its CWD to the held private directory; the app never chdir's.
 * Before/after namespace checks detect known replacement; they do not provide
 * a custom SQLite VFS or a snapshot against an adversarial same-uid writer. */
#include <dirent.h>
#include <sys/file.h>
static int result_same(const struct stat *a,const struct stat *b) {
    return a->st_dev==b->st_dev && a->st_ino==b->st_ino;
}
static int result_private(const struct stat *s) {
    return S_ISREG(s->st_mode) && s->st_uid==geteuid() && s->st_nlink==1 &&
        (s->st_mode&07777)==0600 && !(s->st_flags&(SF_DATALESS|SF_RESTRICTED));
}
int b06_result_check(const char *path,uint64_t quota,int reading) {
    struct stat parent,named,db,current,lease;
    char folder[1024]; const char suffix[]="/result.sqlite";
    size_t length=strnlen(path,sizeof(folder));
    if(quota<(1u<<20) || quota>(UINT64_C(2)<<30) || length>=sizeof(folder) ||
       length<=sizeof(suffix)-1 || strcmp(path+length-(sizeof(suffix)-1),suffix)) {errno=EINVAL;return -1;}
    memcpy(folder,path,length-(sizeof(suffix)-1));folder[length-(sizeof(suffix)-1)]=0;
    if(fstat(4,&parent) || !S_ISDIR(parent.st_mode) || parent.st_uid!=geteuid() ||
       (parent.st_mode&07777)!=0700) {errno=EPERM;return -1;}
    int fresh=b06_open_root(folder);if(fresh<0)return -1;
    int code=fstat(fresh,&named);close(fresh);
    if(code || !result_same(&parent,&named) || fstat(5,&db) || !result_private(&db) ||
       fstatat(4,"result.sqlite",&current,AT_SYMLINK_NOFOLLOW) || !result_private(&current) || !result_same(&db,&current) ||
       fstat(6,&lease) || !result_private(&lease) ||
       fstatat(4,"owner.lock",&current,AT_SYMLINK_NOFOLLOW) || !result_private(&current) || !result_same(&lease,&current) ||
       flock(6,LOCK_EX|LOCK_NB)) {errno=ESTALE;return -1;}
    int listing=openat(4,".",O_RDONLY|O_CLOEXEC|O_DIRECTORY|O_NOFOLLOW_ANY);
    if(listing<0)return -1;
    DIR *dir=fdopendir(listing);if(!dir){close(listing);return -1;}
    uint64_t bytes=0,allocated=0;unsigned count=0;struct dirent *entry;
    errno=0;int failed=0;
    while((entry=readdir(dir))) {
        if(!strcmp(entry->d_name,".")||!strcmp(entry->d_name,".."))continue;
        if(++count>3 || (strcmp(entry->d_name,"result.sqlite") && strcmp(entry->d_name,"owner.lock") &&
           (strcmp(entry->d_name,"result.sqlite-journal") || reading))) {failed=1;errno=ESTALE;break;}
        struct stat s;
        if(fstatat(4,entry->d_name,&s,AT_SYMLINK_NOFOLLOW) || !result_private(&s) || s.st_dev!=parent.st_dev ||
           s.st_size<0 || s.st_blocks<0 || (uint64_t)s.st_size>quota-bytes || (uint64_t)s.st_blocks>quota/512-allocated/512) {
            failed=1;errno=EFBIG;break;
        }
        bytes+=(uint64_t)s.st_size;allocated+=(uint64_t)s.st_blocks*512;
    }
    int saved=errno;closedir(dir);if(failed || saved){errno=saved?saved:ESTALE;return -1;}
    return 0;
}
int b06_result_pin(void) {return fchdir(4);}
int b06_result_directory(uint64_t *device,uint64_t *inode) {
    struct stat value;if(fstat(4,&value))return -1;
    *device=(uint32_t)value.st_dev;*inode=value.st_ino;return 0;
}
