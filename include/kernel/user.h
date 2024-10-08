struct stat;

// system calls
// 系统调用
int fork(void);
int exit(void) __attribute__((noreturn));
int wait(void);
int pipe(int *);
int write(int, void *, int);
int read(int, void *, int);
int close(int);
int kill(int);
int exec(char *, char **);
int open(char *, int);
int mknod(char *, short, short);
int unlink(char *);
int fstat(int fd, struct stat *);
int link(char *, char *);
int mkdir(char *);
int chdir(char *);
int dup(int);
int getpid(void);
char *sbrk(int);
int sleep(int);
int uptime(void);
