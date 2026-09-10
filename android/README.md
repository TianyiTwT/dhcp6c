# android/ —— Android 上可用的 dhcp6c

这个目录让本 fork 能编出一个**在 Android 上真正能跑的 `dhcp6c`**，用作
「Android DHCPv6 有状态地址分配（IA_NA）客户端模块」的传输层。

## 为什么需要它

Android 从 6.0 起自带 DHCPv6 客户端（NetworkStack / IpClient），它随网络起来后
**长期占用 UDP 546 端口**（只发带 IA_PD 的 Solicit 且无限重传，socket 不释放）。
于是任何外部客户端 `bind(546)` 必然 `EADDRINUSE`。

本 fork 的应对：**收发下沉到 AF_PACKET 二层**，绕开 UDP 端口命名空间。
协议逻辑（状态机、选项、事务 ID）与上游完全一致，只替换了底层收发。
全部新增代码在 `#ifdef __ANDROID__` 内，对上游 BSD/Linux 构建**零影响**。

## 依赖

| 依赖 | 说明 |
|---|---|
| Android NDK | r25+ 均可。优先读 `$ANDROID_NDK_HOME`，否则自动探测常见安装位置，也可 `--ndk` 指定 |
| bison / flex | 本仓库不提交生成的 parser。优先用 PATH 里的，否则用 WinFlexBison 便携版（`--wfb`） |
| adb | 仅 `--push` 时需要（默认取 PATH 里的 `adb`，可用 `$ADB` 覆盖） |

## 构建

```sh
sh android/build.sh                                  # 默认 arm64-v8a
sh android/build.sh --abi arm64-v8a,armeabi-v7a      # 多 ABI
sh android/build.sh --out /tmp/out --prefix /data/adb/dhcp6c
sh android/build.sh --push                           # 编完推到设备 /data/local/tmp
```

产物：`android/dist/dhcp6c-<abi>`；中间目标文件在 `android/build/<abi>/`
（两者都已被 `.gitignore` 忽略）。

`--prefix` 决定编译期写死的 `SYSCONFDIR` / `LOCALDBDIR`，默认 `/data/adb/dhcp6c`。
改它会同时改变默认配置文件路径与 DUID/租约的存放位置。

## 与下游模块的接口契约

下游拿到的就是 `android/dist/dhcp6c-<abi>` 一个文件。它期望：

1. **配置文件** 放在 `<prefix>/dhcp6c.conf`（模板见 `dhcp6c.conf.in`，
   把 `__IFNAME__` 替换成真实接口名，通常 `wlan0`）。
2. **启动时必须带 `-p`** 指定 pid 文件，例如
   `dhcp6c -f -p <prefix>/dhcp6c.pid -c <prefix>/dhcp6c.conf`。
   编译期 pid 文件默认是 `/var/run/dhcp6c.pid`，Android 上没有 `/var/run`，
   而该文件在 `-f` 模式下也会被无条件打开，失败即退出。
3. **回调脚本** 见 `dhcp6c-script`，放在配置里 `script` 指向的路径。
   地址由 dhcp6c 自己通过 `ifaddrconf()` 写入内核，**脚本不要代劳改地址**。
4. **持久化**：DUID 存在 `<prefix>/dhcp6c_duid`。只要它和配置里的 IAID 不变，
   冷启动拿回的地址就不变——地址稳定性不需要额外机制。
5. **权限**：AF_PACKET 需要 `CAP_NET_RAW`。KernelSU/Magisk 的 root 有。

## 两个已经踩过的坑（改代码前务必看）

1. **BPF 过滤器的 `next header` 偏移是 20，不是 6。**
   以太头占 14 字节，该字段在 IPv6 头内偏移 6。写成 `ldb [6]` 会读到目的 MAC
   的最后一字节，判据恒假、服务端回包全被拒，症状是「发得出去、永远没回应」——
   与「网络不支持 IA_NA」一模一样。同时过滤器必须收窄（只放行 UDP 546/547）：
   未绑接口时 BPF 对每个入帧求值，放行即唤醒 `select()`；全放行时实测空载
   约 20 次/秒唤醒、流量下逐包唤醒，收窄后均为 0 唤醒。
2. **IPv6 下 UDP 校验和必须自算，且 `htons()` 后写回。**
   AF_PACKET 发送时内核不代算；少一个 `htons()` 服务端会**静默丢弃**。

## 许可

与上游一致，BSD-3-Clause。
