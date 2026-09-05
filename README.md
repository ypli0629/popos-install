# popos-install

Pop!_OS 24.04 系统初始化脚本集合（COSMIC 桌面）。

## 目录结构

```
popos-install/
├── install.sh          # 主入口
├── lib/
│   └── utils.sh        # 公共工具函数（日志、git clone、zshrc 写入等）
└── scripts/
    ├── kernel.sh       # 安装 Ubuntu 6.8 内核并设为默认引导（修复 kernel ≥6.11 睡眠/重启回归）
    ├── brew.sh         # Homebrew + 开发工具
    ├── fcitx.sh        # fcitx5 中文输入法（rime）
    ├── flatpak.sh      # Flatpak 应用
    └── zsh.sh          # oh-my-zsh + 插件 + 别名
```

## 使用方式

```bash
git clone git@github.com:ypli0629/popos-install.git
cd popos-install
bash install.sh
```

`install.sh` 会完成系统更新、Docker、SwitchHosts、JetBrains Toolbox 安装后，
自动按顺序调用 `scripts/` 下的所有子脚本。

也可单独运行某个子脚本：

```bash
bash scripts/kernel.sh
```

## 备注

- **NVIDIA 驱动**：由 Pop 官方仓库管理（`nvidia-driver-595` 等），不要使用
  .run 安装器覆盖；`kernel.sh` 安装新内核后会自动校验 DKMS 模块编译状态。
- **kernel.sh 背景**：kernel ≥ 6.11 与 NVIDIA Open 内核模块存在回归——
  睡眠唤醒失败、重启/关机挂死（NVIDIA bug 6120895，open-gpu-kernel-modules
  #1117/#1027）。该脚本降级到 Ubuntu 官方维护的 6.8 内核系列并设为默认引导。
