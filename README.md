# RTSProxy 群晖套件（Synology DSM 6.2.3）

本仓库是 [**plsy1/rtsproxy**](https://github.com/plsy1/rtsproxy) 的**群晖套件编译版**：在原项目源码基础上
增加了 Synology `.spk` 套件的打包支持，可直接在群晖套件中心安装。

> **原项目仓库**：<https://github.com/plsy1/rtsproxy>
> 项目的功能说明、命令行参数、WebUI 使用、OpenWrt 适配等文档，请以原仓库为准。

---

## 功能特性

- **自定义端口**：安装向导可指定监听端口（默认 `8554`），代理服务与管理面板共用该端口。
- **桌面图标**：安装完成后 DSM 桌面自动生成 RTSProxy 图标，点击即打开 `/admin/` 管理面板。
- **端口联动**：所选端口会同步写入防火墙转发规则与桌面图标配置，改端口后图标依然正确。
- **安全运行**：后台服务以受限用户 `sc-rtsproxy` 运行，仅安装脚本以 root 执行。

## 下载与安装

1. 到本仓库 [Releases](https://github.com/srfj/Synology-rtsproxy/releases) 下载 `rtsproxy-<版本>.spk`；
2. 打开群晖 **套件中心 → 手动安装**，选择该 `.spk` 文件；
3. 按向导设置监听端口，等待安装完成；
4. 回到 DSM 桌面，点击 **RTSProxy** 图标打开管理面板。

**支持环境**：DSM 6.2.3-25426 及以上（`os_min_ver="6.2.3-25426"`）。

**架构**：`apollolake avoton braswell broadwell broadwellnk bromolow cedarview denverton dockerx64 geminilake grantley purley kvmx64 v1000 x86 x86_64`

## 从源码构建

### 依赖

`meson`、`ninja`、`curl`（Debian/Ubuntu 可 `pip install meson ninja`）。

### 构建命令

```bash
./synology/build_synology.sh
```

### 产物

```
bin/synology/rtsproxy-<版本>.spk
```

### 构建流程

1. **交叉工具链**：首次构建时下载 `x86_64-unknown-linux-musl` 到 `toolchains/`，之后复用；
2. **静态编译**：生成 meson cross file，以 `-Disstatic=true` 编译出**全静态**二进制，
   避免依赖 NAS 上的 glibc 版本；
3. **strip**：手动剥离调试符号（meson 只在 `install` 阶段 strip，本流程不执行 install）；
4. **组装负载**：打包 `package.tgz`（内含 `bin/rtsproxy`、`webui/`、`app/`）；
5. **生成 SPK**：将 `package.tgz` 的 md5 写入 `INFO` 的 `checksum`，最终以**未压缩 tar** 打包为 `.spk`。

## 目录结构

```
synology/
├── build_synology.sh          # 构建入口
└── spk/                       # SPK 模板
    ├── INFO.template          # 套件元数据（版本 / 架构 / 桌面图标 / 端口）
    ├── WIZARD_UIFILES/
    │   └── install_uifile     # 安装向导的端口设置页
    ├── PACKAGE_ICON(.256).PNG # 套件中心图标
    ├── conf/
    │   ├── privilege          # 运行用户 sc-rtsproxy；安装脚本以 root 运行
    │   └── resource           # 端口转发配置 + /usr/local/bin 链接
    ├── app/
    │   ├── config             # DSM 桌面图标定义
    │   ├── rtsproxy.sc        # 防火墙端口转发（8554/tcp）
    │   └── images/            # 桌面图标各尺寸
    └── scripts/
        ├── installer          # 通用安装器：pre/post + inst/uninst + upgrade
        ├── service-setup      # 套件专有变量与函数（端口持久化、端口改写）
        └── start-stop-status  # 启停脚本
```

## 安装后的运行行为

- 安装向导把所选端口存到 `/var/packages/rtsproxy/etc/installer-variables`；
- `service_postinst` 校验端口（非法或越界回退 `8554`），并用 `sed` 把端口写进
  `app/config`（桌面图标）与 `app/rtsproxy.sc`（防火墙规则），使二者与向导一致；
- 服务以受限用户 `sc-rtsproxy` 运行，命令为
  `bin/rtsproxy -p <端口> -w --log-file <var>/rtsproxy.log`；
- 工作目录为套件安装目录（`webui/` 相对工作目录加载）。

## 踩坑记录

以下问题均在真机安装调试中实际遇到，供后续改动参考。

### 1. 许可协议页空白，勾选后「下一步」仍不可用

- **现象**：手动安装第二步「许可协议」正文全空白，勾选复选框也无法继续。
- **根因**：SPK 根目录（与 `INFO` 同级）缺少 `LICENSE` 文件。DSM 安装向导用该文件渲染许可页，
  文件缺失时页面空白且无法通过。
- **修复**：构建时把仓库根目录的 `LICENSE` 复制到 SPK 根目录，并确保内容以换行结尾
  （`build_synology.sh` 中用 `tail -c 1` 判断后补 `\n`），权限 `644`。

### 2. 许可协议页点击「下一步」完全无反应

- **现象**：许可页内容与复选框均正常，点「下一步」静默无反应（无报错弹窗）。
- **根因**：`WIZARD_UIFILES/install_uifile` 中使用了非标准的 `validator` 块，
  字段名写成了 `error`（官方为 `errorText`），向导构建下一步时失败。
- **修复**：直接移除 `validator`，端口合法性改由 `service_postinst` 中的 `case` 判断完成。
  **经验：向导文件越简单越稳，复杂校验放到 postinst 做。**

### 3. 打包 / 解包的格式细节

- SPK 本身是**未压缩 tar**，解包要用 `tar xf`，不能用 `tar xzf`；内层 `package.tgz` 才是 gzip。
- `INFO` 的 `checksum=` 是 `package.tgz` 的 md5，**不是**整个 `.spk` 的 md5，
  写错会导致套件中心校验失败。

### 4. 安装脚本的两个坑

- `save_wizard_variables` 不能依赖 `$RM` / `$MKDIR`：这两个变量在安装器执行上下文中并未定义，
  直接调用会导致保存失败；改用绝对路径 `/bin/rm -rf`、`/bin/mkdir -p`。
- `preinst` / `postinst` 需要 root 权限（建软链、改属主、写防火墙规则），
  必须在 `conf/privilege` 的 `ctrl-script` 中把各 action 显式声明为 `"run-as": "root"`。

### 5. 交叉编译

- 使用 musl 工具链产出全静态可执行文件，避免 NAS 上 glibc 版本不匹配；
- 记得手动 strip，否则二进制体积会明显偏大。

### 6. 桌面图标与端口联动

- 桌面图标由 `INFO` 的 `adminprotocol` / `adminport` / `adminurl` 配合 `dsmuidir="app"`
  与 `app/config` 定义；
- 图标打开的端口必须与向导所选端口一致，因此要在 `postinst` 里同步改写 `app/config`，
  否则改动端口后图标仍指向 `8554`。

---

## 相关链接

- 原项目仓库：<https://github.com/plsy1/rtsproxy>
- 本仓库 Releases（SPK 下载）：<https://github.com/srfj/Synology-rtsproxy/releases>

## License

沿用上游项目的开源协议，详见仓库根目录 `LICENSE`。