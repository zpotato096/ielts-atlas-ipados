# IELTS Atlas iPadOS 移植源码

将 IELTS Atlas v0.6.3.2 装入 iPadOS 应用，提供内置 WebKit、离线运行、本地题库导入，以及通过 `.atlasbackup` 导出和恢复练习记录、设置及导入资料。

本仓库包含 iPadOS 包装层及构建脚本。题库和网页运行文件由使用者从 [上游发布页](https://github.com/sallowayma-git/IELTS-practice/releases/tag/v0.6.3.2) 下载后，在本机加入。上游作者及各第三方素材权利人的署名和授权见原项目。

## 本地构建

需要 macOS、Xcode（含 iPhoneOS 17 或更新 SDK）和 Python 3。从上游发布页下载 `ielts-practice-0.6.3.2.zip` 并解压，将下方路径替换成解压后含有 `index.html` 的目录。

```sh
app="dist/Payload/IELTSAtlas.app"
mkdir -p "$app/Web" "$app/Licenses"
cp -R /path/to/extracted-release/. "$app/Web/"
cp Info.plist "$app/"
cp native/ipad.js native/memory.js "$app/"
cp LICENSE "$app/Licenses/GPL-3.0.txt"
cp native/HTTP/LICENSE "$app/Licenses/GCDWebServer.txt"
cp native/miniz/LICENSE "$app/Licenses/miniz.txt"
python3 native/build.py "$app/IELTSAtlas"
codesign --force --sign - "$app"
(cd dist && zip -qry IELTS-Atlas-iPadOS.ipa Payload)
```

生成的 IPA 可以交由 iLoader 签名。公开源码版的本地构建使用系统默认图标。
