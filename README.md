# TVBox-Swift

![Platform iOS | macOS](https://img.shields.io/badge/Platform-iOS%20%7C%20macOS-blue.svg)
![Swift Version](https://img.shields.io/badge/Swift-6%20toolchain%20(Swift%205%20mode)-orange.svg)
![Xcode Version](https://img.shields.io/badge/Xcode-16.0+-blue.svg)

**TVBox-Swift** 是一套基于原生 Swift & SwiftUI 构建的跨平台多媒体应用核心工程。它同时支持 macOS 和 iOS 设备，致力于在双端提供无缝、现代且极其流畅的视听体验。

## ✨ 核心特性

- 🎯 **真正的原生跨平台 (Native Cross-platform)**
  - 基于最新的 SwiftUI 和 SwiftData，一套代码覆盖 macOS (14.0+) 与 iOS (17.0+)。
  - 高度针对多端设备的特定交互形式进行原生级适配与优化。
- 🎨 **前沿的 UI 视觉 (Modern UI & Glassmorphism)**
  - 全新的毛玻璃 (Glassmorphism) 视觉设计体系。
  - 精美流畅的重构动画与微交互，从列表到播放页全系更新。
  - 原生级体验的暗黑模式 (Dark Mode) 全方位支持。
- 🧩 **全方位的媒体功能栈 (Media Stack)**
  - **点播中心 (VOD Center):** 整合了智能资源检索、卡片化视觉呈现与多级详情页。
    - *生态支持:* 原生支持解析主流的 CMS JSON/XML 数据源接口 (`type=0`, `type=1`)，以及由服务端执行爬虫规则的 T4 远程接口 (`type=4`，如 drpy-node)。
    - *暂不支持:* 由于 iOS/macOS 平台原生限制与环境安全，内核未集成基于 Java 引擎或 Rhino 逻辑层，**不支持** `type=3` (Spider / Jar) 等依赖动态脚本执行的复杂爬虫源。
  - **直播支持 (Live):** 稳定的流媒体播放基础构件支持。
  - **内容枢纽 (Content Hub):** 便捷的搜索、智能历史记录流、一键收藏管理。
- ⚙️ **健壮的业务底层 (Robust Foundation)**
  - **持久化:** 基于苹果全新 `SwiftData` 技术的现代化缓存与本地数据存储模块。
  - **数据层:** 兼容性极强的网络接口解析引擎，支持非标准的 JSON/XML 接口容错处理与数据清洗。

## 🛠 技术栈

* **语言**: Swift（Swift 6 编译器，Swift 5 语言模式）
* **UI 框架**: SwiftUI
* **数据持久化**: SwiftData
* **播放内核**: AVPlayer + VLCKit（SPM 包 `vlckit-spm` 3.6.x）
* **测试**: Swift Testing（`tvboxTests` target，挂在 iOS 应用上运行）
* **工程化管理**: XcodeGen (>= 2.35)，仅在修改 `project.yml` 后需要重新生成工程

---

## 🔍 与安卓参考版差异

以下差异基于当前仓库代码：

1. **源类型支持范围不同**
   - Swift 版支持 `type=0/1/4`（XML/JSON/Remote）。T4 源播放前会像安卓版一样请求 `play` 接口换取真实地址，并把返回的请求头交给播放器（VLC 内核只能携带 User-Agent 与 Referer，需要 Cookie 等请求头时请用系统播放器）。
   - Swift 版暂不支持 `type=3 (JAR/JS/PY Spider)` 动态脚本源，源列表按 `api` 标注为 JAR / JS / PY / PHP。
   - 接入 drpy-node 等 T4 服务时，配置地址要用对外地址（drpy-node 为 `http://<服务器IP>:5757/config/1`）：不带 `/1` 时生成的站点地址指向 `127.0.0.1`，在其他设备上无法访问。
2. **配置兼容能力不同**
   - 安卓版支持加密配置解密、`clan://`、相对路径修复、独立直播配置加载等。
   - Swift 版当前为常规 URL 拉取 + 注释容错解析。
3. **解析链路能力不同**
   - 安卓版支持嗅探/解析切换、规则引擎与相关过滤策略。
   - Swift 版当前仅解析并展示解析器配置数量，未接入完整播放解析链路：`play` 接口返回 `parse=1` / `jx=1`（需要嗅探或解析）的剧集会提示暂不支持，`proxy://` 本地代理地址同样不支持。
4. **播放器能力不同**
   - 安卓版支持系统/IJK/EXO/外部播放器等多模式。
   - Swift 版当前支持系统 `AVPlayer` 与 `VLCKit`（iOS/macOS）双引擎切换，IJK/EXO/外部播放器仍未接入。
5. **字幕体系不同**
   - 安卓版支持字幕搜索、本地字幕、样式/延迟调节、内嵌轨道等。
   - Swift 版当前尚未接入完整字幕功能。
6. **直播高级能力不同**
   - 安卓版支持 EPG、回看/时移、分组密码、直播设置分组等。
   - Swift 版当前已支持基础直播分组、线路切换与失败自动切线，支持直播配置中的 `ua` 字段（列表下载与播放均使用）；EPG 仍为简化实现。
   - 直播地址需要是包含 `lives` 的 JSON 配置，暂不支持直接填写 M3U/TXT 列表地址。
7. **筛选与检索形态不同**
   - 安卓版具备分类筛选、快速搜索、复选搜索等界面与交互。
   - Swift 版当前为基础搜索与分类浏览。
8. **远程控制与推送不同**
   - 安卓版具备本地控制服务与推送/遥控相关能力。
   - Swift 版当前未提供该能力。
9. **设置项覆盖度不同**
   - 安卓版设置项更细（DoH、渲染/缩放、历史条数、M3U8 净化、备份恢复等）。
   - Swift 版当前保留核心常用设置。

---

## 🚀 快速开始

仓库已提交 `tvbox.xcodeproj`，克隆后可直接用 Xcode 打开，无需先生成工程。

### 1. 环境准备
*   **macOS**（与所用 Xcode 版本匹配）
*   **Xcode 16.0** 或以上版本：工程文件格式（objectVersion 77）、`@retroactive` 与 Swift Testing 都依赖 Xcode 16 的 Swift 6 工具链。当前已在 **Xcode 26.6** 上验证构建与测试，更低版本未做验证。
*   **XcodeGen**（可选，仅修改 `project.yml` 后需要）：`brew install xcodegen`

### 2. 修改工程配置（可选）
`project.yml` 是工程模板。只有修改了它才需要重新生成工程，并检查生成结果：
```bash
scripts/check_project_yml.sh   # 检查重复键（YAML 会静默合并重复的 target 等配置）
xcodegen generate
git diff tvbox.xcodeproj       # 确认工程变更符合预期后再提交
```

### 3. 构建、运行与测试
在 Xcode 中选择 Scheme（`tvbox` 对应 iOS，`tvbox-macOS` 对应原生 macOS）后 `Command + R`。不需要开发者账号也可以在命令行构建与测试：
```bash
# macOS（ad-hoc 签名）
xcodebuild -project tvbox.xcodeproj -scheme tvbox-macOS -configuration Debug \
  -destination 'platform=macOS' build

# iOS 模拟器构建 / 单元测试（设备名可通过 xcrun simctl list devices available 查看）
xcodebuild -project tvbox.xcodeproj -scheme tvbox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' build
xcodebuild -project tvbox.xcodeproj -scheme tvbox \
  -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test
```

> **平台说明**：iOS target 不支持 Mac Catalyst（VLCKit 3.6 的 XCFramework 不含 Catalyst 切片），在 Mac 上请使用原生 `tvbox-macOS` target。真机安装与 IPA 导出需要使用你自己的开发者团队签名。

---

### iOS 版本打包

`package_ios.sh` 面向已具备企业/分发证书的维护者，运行前需要准备：

1. `IOS-key/secrets.sh`：定义 `P12_PASSWORD`、`PROVISION_UUID`、`TEAM_ID`、`BUNDLE_ID`、`SIGNING_IDENTITY`；
2. `IOS-key/cert.p12` 与 `IOS-key/cert.mobileprovision`（`IOS-key/` 已在 `.gitignore` 中）；
3. `ExportOptions.plist` 中的 `teamID`、`method`、`signingCertificate` 与上述证书一致；
4. 已安装 XcodeGen（脚本会执行 `xcodegen generate`）。

```bash
chmod +x package_ios.sh
./package_ios.sh
```

**注意**：
- 脚本会把证书导入登录钥匙串，并用空密码执行 `security unlock-keychain`；若你的登录钥匙串设置了密码，请先手动解锁，否则脚本会在该步骤中止。
- 找到 `ExportOptions.plist` 时会导出 `TVBox.ipa`，否则只生成 `build/tvbox.xcarchive`。
- 也可以在 Xcode 中选择 `tvbox` scheme，通过 `Product > Archive` 手动打包。

## 📦 macOS 独立打包

项目已内置自动化打包脚本 `package_mac.sh`。当您需要分发 macOS 版本时，直接运行即可自动清理缓存、构建并生成免安装的 `.dmg` 拖拽式安装包。

```bash
chmod +x package_mac.sh
./package_mac.sh
```

> **成功输出提示:** `✅ 打包完成！生成文件: TVBox-macOS.dmg`

---

## 📂 简明目录结构

```text
├── tvbox
│   ├── Models/         # 数据模型定义
│   ├── ViewModels/     # 业务逻辑与状态管理 (MVVM)
│   ├── Views/          # 所有的 SwiftUI 原生视图组件
│   ├── Services/       # 网络层、配置解析层等外部服务交互
│   ├── Persistence/    # 数据库 (SwiftData) 配置与读写管理
│   ├── Utils/          # 通用的帮助类与扩展函数
│   └── Assets.xcassets # 资源文件集、图标与预设全局色彩 (AccentColor)
├── tvboxTests/         # 单元测试（Swift Testing）
├── tvbox.xcodeproj     # 已提交的 Xcode 工程
├── project.yml         # XcodeGen 的工程模板描述文件
├── scripts/            # 工程辅助脚本（project.yml 重复键检查）
├── package_ios.sh      # iOS 归档/导出脚本（需要自备签名材料）
├── ExportOptions.plist # IPA 导出配置
└── package_mac.sh      # macOS DMG 打包脚本
```

---

## 📜 开源协议

本项目采用 [MIT License](./LICENSE) 开源发布。

---

## ⚠️ 开源免责声明 (Disclaimer)

**本项目仅供编程技术交流、学习 Swift 与 SwiftUI 原生应用开发原理之目的。**

1. 开发者不对本项目代码产生的任何直接或间接后果负责。
2. 本项目**不提供、不内置、不分发**任何形式的具体影视资源、播放源配置接口（如接口 URL、JSON 规则等）。
3. 使用本项目所导致的所有合法性与知识产权纠纷（包括但不限于使用者自行导入第三方规则/接口而引发的版权问题），由使用者自行承担全部法律责任。
4. 本应用旨在作为一个本地多媒体客户端工具框架进行技术探讨，任何以此框架衍生的商业化产品与违法行为均与原作者无关。如果您下载、安装、编译或使用了本项目，即代表您理解并完全接受本免责声明之所有条款。
