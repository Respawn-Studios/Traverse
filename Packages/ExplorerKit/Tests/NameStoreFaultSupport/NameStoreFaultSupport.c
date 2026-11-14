#include "NameStoreFaultSupport.h"
#include <sqlite3.h>
#include <string.h>
#include <pthread.h>
#include <limits.h>

typedef struct FaultFile {
    sqlite3_file base;
    sqlite3_file *real;
    int role;
    int eligible;
} FaultFile;
static sqlite3_vfs lane;
static sqlite3_vfs *native;
static char root[PATH_MAX];
static pthread_mutex_t mutex = PTHREAD_MUTEX_INITIALIZER;
static int operation, occurrence, selected_role, seen, hits;

static int eligible(const char *name) {
    size_t count = strlen(root);
    return name && strncmp(root, name, count) == 0 && name[count] == '/';
}
static int trip(int op, int role, int allowed) {
    int result = 0;
    pthread_mutex_lock(&mutex);
    if (allowed && operation == op && (!selected_role || selected_role == role)) {
        ++seen;
        if (seen == occurrence) { ++hits; result = 1; }
    }
    pthread_mutex_unlock(&mutex);
    return result;
}
void menames_fault_arm(int op, int nth, int role) {
    pthread_mutex_lock(&mutex);
    operation = op; occurrence = nth; selected_role = role; seen = 0; hits = 0;
    pthread_mutex_unlock(&mutex);
}
int menames_fault_hits(void) { return hits; }
int menames_fault_seen(void) { return seen; }

static FaultFile *file(sqlite3_file *f) { return (FaultFile *)f; }
static int fClose(sqlite3_file *f) { return file(f)->real->pMethods->xClose(file(f)->real); }
static int fRead(sqlite3_file *f, void *p, int n, sqlite3_int64 off) { return file(f)->real->pMethods->xRead(file(f)->real,p,n,off); }
static int fWrite(sqlite3_file *f, const void *p, int n, sqlite3_int64 off) {
    FaultFile *w = file(f);
    if (trip(1,w->role,w->eligible)) return SQLITE_IOERR_WRITE;
    return w->real->pMethods->xWrite(w->real,p,n,off);
}
static int fTruncate(sqlite3_file *f, sqlite3_int64 n) {
    FaultFile *w = file(f);
    if (trip(3,w->role,w->eligible)) return SQLITE_IOERR_TRUNCATE;
    return w->real->pMethods->xTruncate(w->real,n);
}
static int fSync(sqlite3_file *f, int flags) {
    FaultFile *w = file(f);
    if (trip(2,w->role,w->eligible)) return SQLITE_IOERR_FSYNC;
    return w->real->pMethods->xSync(w->real,flags);
}
static int fSize(sqlite3_file *f, sqlite3_int64 *n) { return file(f)->real->pMethods->xFileSize(file(f)->real,n); }
static int fLock(sqlite3_file *f, int n) { return file(f)->real->pMethods->xLock(file(f)->real,n); }
static int fUnlock(sqlite3_file *f, int n) { return file(f)->real->pMethods->xUnlock(file(f)->real,n); }
static int fReserved(sqlite3_file *f, int *n) { return file(f)->real->pMethods->xCheckReservedLock(file(f)->real,n); }
static int fControl(sqlite3_file *f, int n, void *p) { return file(f)->real->pMethods->xFileControl(file(f)->real,n,p); }
static int fSector(sqlite3_file *f) { return file(f)->real->pMethods->xSectorSize(file(f)->real); }
static int fDevice(sqlite3_file *f) { return file(f)->real->pMethods->xDeviceCharacteristics(file(f)->real); }
static int fMap(sqlite3_file *f, int i, int n, int e, void volatile **p) {
    return file(f)->real->pMethods->xShmMap(file(f)->real,i,n,e,p);
}
static int fShmLock(sqlite3_file *f, int i, int n, int flags) { return file(f)->real->pMethods->xShmLock(file(f)->real,i,n,flags); }
static void fBarrier(sqlite3_file *f) { file(f)->real->pMethods->xShmBarrier(file(f)->real); }
static int fUnmap(sqlite3_file *f, int n) { return file(f)->real->pMethods->xShmUnmap(file(f)->real,n); }
static int fFetch(sqlite3_file *f, sqlite3_int64 off, int n, void **p) {
    const sqlite3_io_methods *m = file(f)->real->pMethods;
    if (m->iVersion >= 3 && m->xFetch) return m->xFetch(file(f)->real,off,n,p);
    *p = 0; return SQLITE_OK;
}
static int fUnfetch(sqlite3_file *f, sqlite3_int64 off, void *p) {
    const sqlite3_io_methods *m = file(f)->real->pMethods;
    return m->iVersion >= 3 && m->xUnfetch ? m->xUnfetch(file(f)->real,off,p) : SQLITE_OK;
}
static const sqlite3_io_methods methods = {3,fClose,fRead,fWrite,fTruncate,fSync,fSize,fLock,fUnlock,fReserved,fControl,fSector,fDevice,fMap,fShmLock,fBarrier,fUnmap,fFetch,fUnfetch};
static int vOpen(sqlite3_vfs *v, const char *name, sqlite3_file *f, int flags, int *out) {
    (void)v;
    FaultFile *w = file(f); memset(w,0,sizeof(*w));
    w->real = (sqlite3_file *)((unsigned char *)f + sizeof(*w));
    memset(w->real,0,native->szOsFile);
    int result = native->xOpen(native,name,w->real,flags,out);
    if (result == SQLITE_OK) {
        w->role = flags & SQLITE_OPEN_MAIN_DB ? 1 : flags & SQLITE_OPEN_MAIN_JOURNAL ? 2 : 0;
        w->eligible = eligible(name); w->base.pMethods = &methods;
    }
    return result;
}
static int vDelete(sqlite3_vfs *v, const char *name, int sync) {
    (void)v;
    if (trip(4,2,eligible(name))) return SQLITE_IOERR_DELETE;
    return native->xDelete(native,name,sync);
}
static int vAccess(sqlite3_vfs *v, const char *n, int flags, int *p) { (void)v; return native->xAccess(native,n,flags,p); }
static int vFull(sqlite3_vfs *v, const char *n, int count, char *p) { (void)v; return native->xFullPathname(native,n,count,p); }
static void *vDlOpen(sqlite3_vfs *v, const char *n) { (void)v; return native->xDlOpen(native,n); }
static void vDlError(sqlite3_vfs *v, int n, char *p) { (void)v; native->xDlError(native,n,p); }
static void (*vDlSym(sqlite3_vfs *v, void *p, const char *n))(void) { (void)v; return native->xDlSym(native,p,n); }
static void vDlClose(sqlite3_vfs *v, void *p) { (void)v; native->xDlClose(native,p); }
static int vRandom(sqlite3_vfs *v, int n, char *p) { (void)v; return native->xRandomness(native,n,p); }
static int vSleep(sqlite3_vfs *v, int n) { (void)v; return native->xSleep(native,n); }
static int vTime(sqlite3_vfs *v, double *p) { (void)v; return native->xCurrentTime(native,p); }
static int vError(sqlite3_vfs *v, int n, char *p) { (void)v; return native->xGetLastError(native,n,p); }
static int vTime64(sqlite3_vfs *v, sqlite3_int64 *p) { (void)v; return native->xCurrentTimeInt64(native,p); }
int menames_fault_register(const char *generated_root) {
    if (native || !generated_root || strlen(generated_root) >= sizeof(root)) return SQLITE_MISUSE;
    native = sqlite3_vfs_find(0);
    if (!native || native->iVersion < 2) return SQLITE_NOTFOUND;
    strcpy(root,generated_root);
    memset(&lane,0,sizeof(lane)); lane.iVersion = 2;
    lane.szOsFile = sizeof(FaultFile) + native->szOsFile; lane.mxPathname = native->mxPathname;
    lane.zName = "menames-generated-faults"; lane.pAppData = native;
    lane.xOpen=vOpen; lane.xDelete=vDelete; lane.xAccess=vAccess; lane.xFullPathname=vFull;
    lane.xDlOpen=vDlOpen; lane.xDlError=vDlError; lane.xDlSym=vDlSym; lane.xDlClose=vDlClose;
    lane.xRandomness=vRandom; lane.xSleep=vSleep; lane.xCurrentTime=vTime; lane.xGetLastError=vError; lane.xCurrentTimeInt64=vTime64;
    return sqlite3_vfs_register(&lane,0);
}
