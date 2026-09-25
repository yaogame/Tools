# DDS（双明手求解器）

这里是 [DDS](https://github.com/dds-bridge/dds) 2.9.0 的源码，作者 Bo Haglund 与 Soren Hein，
采用 Apache License 2.0（见 `DDS-LICENSE.txt`）。本 App 通过 `DDSBridge.h / DDSBridge.cpp` 调用其中的 `SolveBoard`。

对原始源码的改动：
- `src/Par.cpp`：补上 `#include <stdio.h>`（libc++ 下 sprintf 需要它）。
- `src/System.cpp`：在 Apple 平台上把 `popen("sysctl -n hw.memsize")` 改为 `sysctlbyname("hw.memsize", ...)`，
  因为 iOS 不允许使用 `popen`。

未包含：Windows 专用的 `dds.rc`、`Exports.def` 以及各平台 Makefile。
