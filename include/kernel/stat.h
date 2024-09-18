#define T_DIR 1  // Directory
#define T_FILE 2 // File
#define T_DEV 3  // Device

struct stat
{
    short type;        // 文件类型
    int dev;           // 文件系统的磁盘设备
    unsigned int ino;  // Inode编号
    short nlink;       // 指向文件的链接数量
    unsigned int size; // 文件大小(以字节为单位)
};
