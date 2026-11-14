#ifndef NAME_STORE_FAULT_SUPPORT_H
#define NAME_STORE_FAULT_SUPPORT_H
// Named VFS only; never registered as default. Tests are isolated child processes.
int menames_fault_register(const char *generated_root);
void menames_fault_arm(int operation, int occurrence, int role);
int menames_fault_hits(void);
int menames_fault_seen(void);
// operation: write=1, sync=2, truncate=3, delete=4. role: any=0, main=1, journal=2.
#endif
