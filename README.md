# 三色桌宠

<img src="BlackCat/Artwork/tricolor-logo.png" width="160" alt="三位桌宠的手绘合照：DeepSeek、Claude 和 Codex">

**简体中文** · [English](README.en.md)

适用于 macOS 和 Windows 的键鼠桌宠，有三个角色可选。你移动鼠标时，她的目光会先看过去，头部随后转动。你敲键时，她会伸手按下对应的键。轻点她的头，她会微笑，头顶还会飘出小爱心。

## 下载 1.4.3

| 平台 | 下载 |
| --- | --- |
| macOS 12 及以上，Apple 芯片和 Intel | [macOS 1.4.2 通用版 ZIP](https://github.com/Gaoyuan-0423/tricolor-desktop-pet/releases/download/v1.4.2/TricolorPet-1.4.2-macOS-universal.zip) |
| Windows x64 | [Windows 1.4.3 EXE](https://github.com/Gaoyuan-0423/tricolor-desktop-pet/releases/download/v1.4.3/TricolorPet-1.4.3-Windows-x64.exe) |
| 源码 | [1.4.3 源码 ZIP](https://github.com/Gaoyuan-0423/tricolor-desktop-pet/releases/download/v1.4.3/TricolorPet-1.4.3-source.zip) |

1.4.3 更新 Windows 版：深睡时降低动画更新频率，优化 Z 字缓存，并在右键菜单中增加入睡等待设置。Windows 版已交叉编译并通过离屏测试，尚未在 Windows 真机验证。[发行说明与 SHA-256 校验值](https://github.com/Gaoyuan-0423/tricolor-desktop-pet/releases/tag/v1.4.3)

macOS 下载仍为未改动的 1.4.2：动画优先跟随显示器刷新，深睡时减少重复绘制和动画更新，桌宠不再阻止 Mac 闲置休眠。该版本已使用 Developer ID 签名并通过 Apple 公证。

1.4.1 启用了新的三角色手绘图标。Mac 菜单栏会显示当前角色的标志：蓝色角色是鲸鱼，橙色角色是向日葵，白色角色是双角小龙。点击图标即可打开桌宠菜单。Windows 的 EXE 和通知区域也换上了三人合照。

[下载已通过 Apple 公证的 1.4.0](https://github.com/Gaoyuan-0423/tricolor-desktop-pet/releases/tag/v1.4.0)

## 1.4.0 的新互动

默认设置下，空闲约 45 秒，DeepSeek 会端起碗吃白饭，Claude 会翻开花纹书，Codex 会抛起蓝色云朵玩偶再接住。三人的表情会随动作改变。约 60 秒后，她们闭眼睡着，头顶飘出 Zzz。有人按键时，桌宠会轻轻摇头醒来，同时接住第一下敲键。下面的动画来自 Mac 版实际绘制，缩短了等待时间。

![三个角色并排进餐、读书、抛接玩偶，然后入睡并被按键唤醒](docs/images/idle-hobbies.gif)

移动桌面光标时，桌上的小鼠标和握住它的手一起滑动。此时按 D、F 或空格，另一只手仍会按亮对应键。按住头部约 0.35 秒，角色会眯起眼睛，向手指轻蹭。

## 三位桌宠的待机形象

从左到右依次是蓝发的 DeepSeek、橙发的 Claude 和白发龙角的 Codex。点开任意一位可以查看完整尺寸。

<p align="center">
  <a href="docs/images/idle-blue.png"><img src="docs/images/idle-blue.png" alt="蓝发 DeepSeek 的完整待机画面，面前放着蓝色键鼠" width="31%"></a>
  <a href="docs/images/idle-amber.png"><img src="docs/images/idle-amber.png" alt="橙发少女的完整待机画面，面前放着橙色键鼠" width="31%"></a>
  <a href="docs/images/idle-frost.png"><img src="docs/images/idle-frost.png" alt="白发龙角少女的完整待机画面，面前放着淡紫色键鼠" width="31%"></a>
</p>

## 桌宠实际画面

### 握鼠、快打与摸头

三位角色依次握鼠、抬腕、连敲 D、F、J，然后在微笑时再敲一遍。下图用 Mac 版的绘制代码按同一组输入生成，并放慢了触键片段。

![三位角色抬腕、连敲三个键，并在摸头微笑时继续打字](docs/images/typing-and-pats.gif)

### 视线跟随

下方三段 Mac 录屏也按蓝、橙、白排列，每位角色各有一段。光标从窗口一侧移到另一侧时，目光先转过去，头部随后轻轻转动。

<p align="center">
  <a href="docs/images/gaze-blue.gif"><img src="docs/images/gaze-blue.gif" alt="蓝发 DeepSeek 的目光和头部跟随光标左右转动" width="31%"></a>
  <a href="docs/images/gaze-amber.gif"><img src="docs/images/gaze-amber.gif" alt="橙发少女的目光和头部跟随光标左右转动" width="31%"></a>
  <a href="docs/images/gaze-frost.gif"><img src="docs/images/gaze-frost.gif" alt="白发龙角少女的目光和头部跟随光标左右转动" width="31%"></a>
</p>

[查看三个角色向左和向右看的静帧对照，含眼部放大图](docs/images/cursor-tracking.png)

### 摸头

从 1.3.0 起，轻点头顶后，角色先眯眼浅笑，再闭眼，头顶飘出小爱心。持续来回轻抚可以延长笑容。这个过程中，她仍能敲键和握鼠标。

![从左到右，蓝、橙、白三个角色被摸头后闭眼微笑，头顶浮出爱心](docs/images/head-pat.png)

### 握鼠标

上排是三位角色待机时的双手，下排是右手握稳鼠标时的姿势。1.3.0 在握鼠和打字之间加入抬腕过渡。连续敲键时，后续按键可以直接触底，松手后手指自然收回。

![三个角色待机和握鼠时的手部近景](docs/images/mouse-grip.png)

## 运行与操作

- **Mac**　下载 macOS 通用版，解压后将「三色桌宠.app」移入「应用程序」，再打开。要让角色跟随其他应用里的按键，右键角色，点「开启输入监控…」并在系统设置中授权。
- **入睡等待**　Mac 和 Windows 均可右键角色，选择「入睡等待」，设为 15 秒、30 秒、1 分钟、2 分钟、5 分钟或 10 分钟；默认 1 分钟。
- **Windows**　将 Windows x64 版 EXE 放在准备长期使用的文件夹里，双击运行。
- **两个平台**　左键拖动可以移动角色。右键菜单可以切换角色、开关打字声，或将大小调到 50% 至 200%。
- **登录时启动（自 1.3.0 起）**　默认关闭。右键角色，勾选「登录时启动」，下次登录当前账户时桌宠会自动打开。再次点击即可关闭。Mac 提示需要批准时，可从同一菜单打开系统的登录项设置。

## 从源码构建

在仓库根目录打开终端。macOS 需要 Xcode 命令行工具，Windows 需要 Go。

**macOS**

```sh
cd BlackCat
bash build-mac.sh
```

**Windows x64（PowerShell）**

```powershell
cd BlackCat/windows
$env:GOARCH = 'amd64'
go build -trimpath -ldflags='-s -w -H=windowsgui' -o TricolorPet.exe .
```

交叉编译和动作导出的步骤见[项目说明](BlackCat/项目说明.md)。角色原画、手部标注与表情素材见[素材说明](BlackCat/Artwork/素材说明.md)。
