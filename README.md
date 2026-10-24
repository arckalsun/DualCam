# DualCam · 双摄相机

一个 iOS 小 App：**前后摄像头同时取流**，画面默认上下平分，可切换左右，也能拖动分割线调整比例，设置会被记住。拍照和录像都会把两路画面合成为一个文件存进相册。

![真机运行：上为后置、下为前置](docs/device.png)

> 上面这张是 iPhone 13 Pro 上的真实运行画面（后置拍桌面、前置拍天花板）。没有摄像头时进入的演示模式长这样：[模拟器演示](docs/screenshot.png)。

## 功能

| 功能 | 说明 |
| --- | --- |
| 双摄同拍 | `AVCaptureMultiCamSession` 同时驱动后置 + 前置摄像头 |
| 默认上下平分 | 后置在上、前置在下 |
| 一键切换 | 右下角按钮在「上下 / 左右」之间切换 |
| 拖动分割线 | 中间白色手柄可上下/左右拖动，比例限制在 15%–85% |
| 记忆布局 | 方向和比例用 `@AppStorage` 持久化，重启 App 依然保留 |
| 拍照 | 两个摄像头各拍一张全分辨率照片，按当前布局合成一张 JPG 存相册 |
| 录像 | 两路画面实时合成为 1080×1920 的 H.264 视频（带麦克风声音），存相册 |
| 前置镜像 | 预览和合成结果中的前置画面都做了水平镜像，和取景一致 |

## 运行要求

- **真机**：iPhone XS / XR 及更新机型（A12 芯片起），系统 iOS 17.0+
- **模拟器**：没有摄像头，App 会自动进入**演示模式**，可以体验分割线拖动和布局切换，但拍照/录像会提示需要真机
- Xcode 15 及以上（本项目在 Xcode 27.1 上验证通过）

## 在 Xcode 里跑起来

1. 双击打开 `DualCam.xcodeproj`
2. 选中 `DualCam` target → **Signing & Capabilities**
   - 勾选 *Automatically manage signing*
   - Team 选择你自己的 Apple ID（免费账号也可以）
   - 如果提示 bundle ID 被占用，把 `PRODUCT_BUNDLE_IDENTIFIER`（当前是 `com.example.dualcamera`）改成你自己的，例如 `com.你的名字.dualcamera`
3. 顶部选择你的 iPhone（需要先用数据线连接并在手机上「信任此电脑」）
4. `⌘R` 运行

首次启动会依次请求**相机 / 麦克风 / 相册写入**权限，都要允许，否则对应功能不可用。

> 如果误点了「不允许」：到 iPhone 的「设置 → 隐私与安全性 → 相机 / 麦克风 / 照片」里重新打开，回到 App 点「重试」。

## 代码结构

```
DualCam/
├─ DualCam.xcodeproj
└─ DualCam/
   ├─ DualCamApp.swift        App 入口
   ├─ ContentView.swift       界面：双画面布局、分割线拖动、拍照/录像按钮
   ├─ CameraController.swift  多摄会话：输入、输出、预览层、权限
   ├─ CameraPreviewView.swift 把 AVCaptureVideoPreviewLayer 包进 SwiftUI
   ├─ Compositor.swift        把两路画面按布局合成为图片 / 视频帧
   ├─ VideoRecorder.swift     AVAssetWriter 实时合成录像
   ├─ DualPhotoCapture.swift  同时触发两个摄像头拍照并合成
   ├─ PhotoLibrary.swift      写入系统相册
   ├─ LayoutConfig.swift      布局模式、分割比例与区域计算
   └─ Assets.xcassets/        App 图标
```

## 实现要点

- **多摄会话**：每个摄像头各接一个 `AVCaptureVideoDataOutput`（喂合成器）、一个 `AVCapturePhotoOutput`（拍全分辨率照片）和一个预览连接。预览层用 `AVCaptureVideoPreviewLayer(sessionWithNoConnection:)` 创建，手动建连接，这是多摄会话的必需写法。
- **合成策略**：录像是「所见即所得」——按当前布局把两路画面等比填充到各自区域后合成为 1080×1920；拍照同理，只是用 `UIGraphicsImageRenderer` 在原始分辨率上合成。
- **朝向处理**：连接上设置 `videoRotationAngle = 90` 适配竖屏；若某些设备不支持，合成器会自动检测横向 buffer 并旋转，所以两条路径都能得到正的画面。
- **录像时序**：以第一帧的 host time 作为 `startSession` 起点，视频按 30fps 节流写入，音频走透传，避免音画不同步。

## 已知限制

- 界面锁定竖屏（横屏会让取景和合成逻辑复杂不少，这个版本没做）。
- 录像固定输出 1080×1920，暂不支持 4K。
- 分割比例范围 15%–85%，防止某一路被拖到看不见。
- 进入后台会先结束并保存当前录像，再释放摄像头。
- 演示模式下不能拍照/录像，只能体验布局。

## 验证情况

**编译**：Debug（模拟器）、Release（真机 arm64）、Archive 均通过。

**合成逻辑**：用合成图做过离线自检，像素采样确认上下/左右分割位置、90° 旋转方向、前置镜像均正确。

**真机（iPhone 13 Pro / iOS 26.6.1）实测通过**：

- 双摄会话：`multiCamSupported=true`，前后摄像头同时出流，2 个视频输出 + 2 个照片输出 + 麦克风
- 拍照：合成照片保存到相册，两路画面按布局拼接正常
- 录像：`AVAssetWriter` 正常收尾（`status=2`），合成视频保存到相册

真机调试中修掉的三个问题（模拟器都测不出来）：

| 问题 | 原因 | 修法 |
| --- | --- | --- |
| 点拍照闪退 | 多摄会话下 `maxPhotoQualityPrioritization` 被降到 `.balanced`，请求 `.quality` 会抛异常 | 按输出实际上限设置请求值 |
| 停止录像一直转圈 | `finish` 用 `[weak self]`，调用方先释放 recorder，异步 block 空跑 | 改为强捕获 |
| 合成跟不上会堆积 | 每帧都往串行队列塞合成任务 | 加丢帧背压 + 8 秒超时兜底 |

## 打包与分发

已生成可直接安装的 IPA：

```
build/ipa/DualCam.ipa          # 开发签名，536 KB
build/DualCam.xcarchive        # 归档，含 dSYM
```

重新打包：

```bash
xcodebuild archive \
  -project DualCam.xcodeproj -scheme DualCam \
  -configuration Release -destination 'generic/platform=iOS' \
  -archivePath build/DualCam.xcarchive -allowProvisioningUpdates

xcodebuild -exportArchive \
  -archivePath build/DualCam.xcarchive \
  -exportPath build/ipa \
  -exportOptionsPlist ExportOptions.plist -allowProvisioningUpdates
```

**安装 IPA 的两种方式**

1. Xcode → Window → Devices and Simulators → 选中设备 → 把 IPA 拖进「Installed Apps」
2. 用 [Apple Configurator](https://apps.apple.com/cn/app/apple-configurator/id1037126344) 拖入

**这个包的签名限制**（因为用的是免费 Personal Team）：

- 有效期 **7 天**（描述文件 2026-10-28 到期），过期后 App 打不开，重新打包安装即可
- 只能装在 **已注册到该 Team 的设备** 上，目前只有你的 iPhone 13 Pro
- 不能上传 App Store

## 上架 App Store 还差什么

真机上架需要付费开发者账号，免费 Personal Team 做不了：

1. 加入 **Apple Developer Program**（99 美元/年）
2. App Store Connect 里创建 App 记录（名称、SKU、Bundle ID）
3. 把 `ExportOptions.plist` 的 `method` 改成 `app-store`，用 Distribution 证书重新导出
4. 补齐上架材料：图标（已有 1024）、截图（6.9"/6.5" 等尺寸）、隐私说明（相机/麦克风/相册用途）、年龄分级、审核备注
5. 上传（Xcode Organizer 或 `xcrun altool` / `notarytool`）并提交审核

代码侧已经就绪的部分：Bundle ID、版本号、用途描述文案、App 图标。

## License

[MIT](LICENSE) © 2026 arckal
