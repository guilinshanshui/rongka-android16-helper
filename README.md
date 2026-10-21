# Android 16 融卡助手

用于通过 ADB 调用 Android 的 StorageManager，将 SD 卡分区为内部存储或混合存储。

此工具针对 Android 16 上 `sm list-disks adoptable` 返回空的问题做了兼容：检测失败时会临时启用
`sm set-force-adoptable on`，随后重新读取可分区磁盘，并在流程结束时恢复设备的默认设置。

## 支持情况

- Windows PowerShell 5.1 或更高版本
- Android 6.0 及以上
- 已在 Motorola XT2437-4、Android 16、安全补丁 2026-04-01 上完成只读识别测试
- 测试结果：设备与 `disk:179,0` 均可正常识别

## 使用方法

双击 `自动融卡_Android16修复版.cmd`。

只检查设备和 SD 卡、不修改存储：

```powershell
.\自动融卡_Android16修复版.cmd /check
```

主要选项：

1. 内部存储 25%，便携 SD 卡 75%
2. 内部存储 50%，便携 SD 卡 50%
3. 内部存储 75%，便携 SD 卡 25%
4. 整张 SD 卡全部作为内部存储
5. 自定义混合模式比例（便携分区 10-90%）
6. 打开 Android 应用管理
7. 将 APK 安装至 SD 卡
8. 仅检测设备和 SD 卡

## 文件系统

Android 会根据设备能力自动选择文件系统，`sm partition` 不提供手动选择 F2FS 或 ext4 的参数。
对于 SD 卡这类 MMC 设备，Vold 的 `auto` 规则会优先选择 F2FS；无法使用 F2FS 时回退到 ext4。

本工具不会手动运行 `mkfs.f2fs` 或 `mkfs.ext4`。

## 警告

融卡会清空 SD 卡，并创建与当前设备加密密钥绑定的私有存储。

- 整卡私用后，不能把卡直接当作普通 SD 卡在相机、电脑或其他手机上使用。
- 原工具提示：Android 安全补丁在 2022-07 及以后的设备执行融卡，存在无限重启风险。
- 请先完整备份，并确认设备有可用的官方救援或 fastboot 恢复方案。
- 不要在未确认风险的情况下输入脚本要求的 `AGREE`。

## 目录

```text
自动融卡_Android16修复版.cmd   Windows 启动器
Android16Merge.ps1            主程序
adb/                          Windows ADB 工具
```
