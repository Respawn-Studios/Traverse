/* SMB temporary metadata only. Boundary checks are not a same-user race-proof
 * VFS; the parent owns this private directory and holds the exact descriptors. */
#include <sys/stat.h>
#include <sys/file.h>
#include <fcntl.h>
#include <unistd.h>
#include <string.h>
#include <stdint.h>
#include <errno.h>

static int private_file(const struct stat *s) {
    return S_ISREG(s->st_mode) && s->st_nlink==1 && s->st_uid==geteuid() && (s->st_mode&0777)==0600;
}
static int same(const struct stat *a,const struct stat *b) {return a->st_dev==b->st_dev && a->st_ino==b->st_ino;}
static int anchored_directory(const char *path) {
    size_t n=strnlen(path,4096);
    if (n<2 || n>=4096 || path[0]!='/') {errno=EINVAL;return -1;}
    size_t begin=1;
    while (begin<n) {
        size_t end=begin;while(end<n && path[end]!='/')end++;
        size_t count=end-begin;
        if (!count || count>255 || (count==1 && path[begin]=='.') ||
            (count==2 && path[begin]=='.' && path[begin+1]=='.')) {errno=EINVAL;return -1;}
        begin=end+1;
    }
    /* Darwin's all-component no-follow operation preserves the same boundary
     * without requiring directory-read access to every container ancestor.
     * An inherited App Sandbox may access its owned store while correctly
     * refusing enumeration/open of /Users or Library/Containers. No fallback
     * to a symlink-following open is admitted. The held descriptor identity is
     * still checked below, including on every subsequent catalog operation. */
    return open(path,O_RDONLY|O_DIRECTORY|O_CLOEXEC|O_NOFOLLOW_ANY);
}
int mex_smb_store_check(const char *path,int parent_fd,int database_fd,int lease_fd,uint64_t cap,int empty) {
    const char suffix[]="/catalog.sqlite";size_t n=strnlen(path,4096),tail=sizeof(suffix)-1;
    if(n<=tail || n>=4096 || strcmp(path+n-tail,suffix) || cap<(1u<<20) || cap>(512u<<20))return -1;
    char folder[4096];memcpy(folder,path,n-tail);folder[n-tail]=0;
    struct stat parent,fresh,database,current,lease,lease_current;
    if(fstat(parent_fd,&parent) || !S_ISDIR(parent.st_mode) || parent.st_uid!=geteuid() || (parent.st_mode&0777)!=0700)return -1;
    int fd=anchored_directory(folder);if(fd<0)return -1;
    int result=fstat(fd,&fresh);close(fd);
    if(result || !same(&parent,&fresh) || fstat(database_fd,&database) || !private_file(&database) ||
        fstatat(parent_fd,"catalog.sqlite",&current,AT_SYMLINK_NOFOLLOW) || !private_file(&current) || !same(&database,&current) ||
        database.st_dev!=parent.st_dev || fstat(lease_fd,&lease) || !private_file(&lease) ||
        fstatat(parent_fd,"owner.lock",&lease_current,AT_SYMLINK_NOFOLLOW) || !private_file(&lease_current) ||
        !same(&lease,&lease_current) || lease.st_dev!=parent.st_dev || flock(lease_fd,LOCK_EX|LOCK_NB))return -1;
    if(database.st_size<0 || database.st_blocks<0 || (empty && database.st_size))return -1;
    uint64_t size=(uint64_t)database.st_size,allocated=(uint64_t)database.st_blocks*512;
    if(allocated>size)size=allocated;
    const char *sidecars[]={"catalog.sqlite-journal","catalog.sqlite-wal","catalog.sqlite-shm"};
    for(unsigned i=0;i<3;i++) {
        struct stat s;
        if(fstatat(parent_fd,sidecars[i],&s,AT_SYMLINK_NOFOLLOW)) {if(errno==ENOENT)continue;return -1;}
        if(empty || i>0 || !private_file(&s) || s.st_dev!=parent.st_dev || s.st_size<0 || s.st_blocks<0)return -1;
        uint64_t part=(uint64_t)s.st_size,blocks=(uint64_t)s.st_blocks*512;if(blocks>part)part=blocks;
        if(part>cap || size>cap-part)return -1;size+=part;
    }
    return size<=cap ? 0:-1;
}
