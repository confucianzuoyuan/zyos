## 构建镜像

```bash
$ make
```

## 使用qemu测试

```bash
$ make test
```

## 使用gdb进行debug

```bash
$ make debug
```

gdb如下使用：

```
$ gdb
(gdb) set arch i386:x86-64
(gdb) symbol-file build/monk.sys
(gdb) target remote localhost:8864
(gdb) layout src
```

## 清理构建

```bash
$ make clean
```
