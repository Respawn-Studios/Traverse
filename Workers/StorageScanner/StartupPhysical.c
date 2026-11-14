/* Qualified startup mode only. Namespace fstat identities remain the ordinary
 * scanner's contract. Physical identity uses exact public returned masks. */
int b06_physical_identity(int fd,B06Identity *o) {
    if(b06_identity(fd,o))return -1;
    struct attrlist a={0};a.bitmapcount=ATTR_BIT_MAP_COUNT;
    a.commonattr=ATTR_CMN_RETURNED_ATTRS|ATTR_CMN_DEVID|ATTR_CMN_FILEID;
    a.forkattr=ATTR_CMNEXT_REALDEVID|ATTR_CMNEXT_REALFSID;
    unsigned char b[48]={0};
    if(fgetattrlist(fd,&a,b,sizeof(b),FSOPT_ATTR_CMN_EXTENDED|FSOPT_RETURN_REALDEV))return -1;
    uint32_t v[6];memcpy(v,b,sizeof(v));
    uint32_t device,real;uint64_t inode;int32_t fs[2];
    memcpy(&device,b+24,4);memcpy(&inode,b+28,8);memcpy(&real,b+36,4);memcpy(fs,b+40,8);
    if(v[0]!=48 || v[1]!=a.commonattr || v[2] || v[3] || v[4] || v[5]!=a.forkattr ||
       !device || device!=real || !inode) {errno=ENOTSUP;return -1;}
    o->dev=device;o->ino=inode;o->fsid0=fs[0];o->fsid1=fs[1];return 0;
}
int b06_bulk_physical(int fd,void *b,size_t n) {
    struct attrlist a=attrs();return getattrlistbulk(fd,&a,b,n,FSOPT_RETURN_REALDEV);
}
int b06_result_physical_directory(uint64_t *device,uint64_t *inode) {
    B06Identity value;if(b06_physical_identity(4,&value))return -1;
    *device=value.dev;*inode=value.ino;return 0;
}
