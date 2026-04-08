# ratex.el

[English](./README.md)

`ratex.el` 是一个面向 Emacs 的行内数学公式预览原型，底层使用上游
[RaTeX](https://github.com/erweixin/RaTeX) 引擎进行解析和 SVG 渲染。

它的目标是在 Emacs 中提供一个轻量、异步、低打扰的数学公式预览体验。

## 演示

![ratex.el 演示](./assets/demo.gif)

## 功能特性

- 在 Emacs 中异步预览数学公式
- 基于 RaTeX 的 SVG 渲染
- 第一次使用时自动编译后端
- 通过 overlay 显示公式预览
- 支持 `latex-mode`、`LaTeX-mode`、`org-mode`、`markdown-mode`

## 仓库结构

- `vendor/ratex-core`：上游 RaTeX git submodule
- `backend/`：供 Emacs 调用的 Rust 后端进程
- `lisp/`：Emacs Lisp 包源码
- `bin/`：开发辅助脚本
- `test/`：Emacs 侧测试
- `docs/`：项目文档和规划

## 环境要求

- Emacs 29.1 或更新版本
- 安装好的 Rust 工具链和 `cargo`
- clone 时已初始化 submodule

## 安装方式

推荐直接带 submodule 克隆：

```bash
git clone --recurse-submodules https://github.com/gongshangzheng/ratex.el.git
cd ratex.el
```

如果你已经 clone 了仓库但没拉 submodule：

```bash
git submodule update --init --recursive
```

## Emacs 配置

先把仓库中的 `lisp/` 加入 `load-path`，再加载 `ratex`：

```elisp
(add-to-list 'load-path "/path/to/ratex.el/lisp")
(require 'ratex)
```

当前 buffer 手动启用：

```elisp
M-x ratex-mode
```

或者给常见模式自动启用：

```elisp
(require 'ratex)
(ratex-setup)
```

如果你想自己写 hook，也可以这样：

```elisp
(add-hook 'latex-mode-hook #'ratex-mode)
(add-hook 'LaTeX-mode-hook #'ratex-mode)
(add-hook 'org-mode-hook #'ratex-mode)
(add-hook 'markdown-mode-hook #'ratex-mode)
```

## 自动编译机制

`ratex-mode` 启动时会检查后端二进制是否存在：

```text
backend/target/ratex-editor-backend
```

如果二进制不存在，Emacs 会自动从最新的 GitHub Release 下载对应平台的可执行文件：

```bash
https://github.com/gongshangzheng/ratex.el/releases/latest
```

下载成功后，会直接启动 backend。

## 如何使用

当前交互逻辑是：

- 打开并启用 `ratex-mode` 后，会先全量渲染当前 buffer 里的公式
- 光标进入公式后，预览会隐藏
- 光标停留在公式内部时，不会触发持续渲染
- 光标离开该公式后，只会重渲染刚刚编辑的那一段

也就是说，平时不会在每个命令后全量刷新，而是采用“打开时全量渲染 + 编辑时隐藏 + 离开后局部渲染”的模式。

当前原型支持的分隔符有：

- `\(...\)`
- `\[...\]`

本库目前不支持使用美元符号分隔的数学公式写法。请统一使用
`\(...\)` 和 `\[...\]`，这两种形式在当前代码里更简单，也更不容易出错。

默认会跳过这些情况，不做公式渲染：

- 公式位于代码块中（例如 Org src/example/verbatim block，Markdown fenced code block）
- 分隔符被转义时（例如 `\$`、`\\(`、`\\[`）

也可以手动触发当前 buffer 的全量预览刷新：

```elisp
M-x ratex-refresh-previews
```

如果你想手动重新下载 backend：

```elisp
M-x ratex-download-backend-command
```

## 使用示例

在 LaTeX、Org 或 Markdown buffer 里，把光标放在下面的公式内部：

```tex
\(\frac{1}{2}\)
```

或者：

```tex
\[
\int_0^1 x^2\,dx
\]
```

`ratex.el` 会把公式发送给 Rust backend，收到 SVG 后通过 overlay 在 buffer 中显示预览。

## 可配置项

目前比较常用的自定义变量有：

- `ratex-backend-root`：显式指定 ratex.el 仓库根目录
- `ratex-font-size`：发送给 backend 的 SVG 字号
- `ratex-svg-padding`：发送给 backend 的 SVG 边距
- `ratex-render-color`：公式默认渲染颜色（例如 `#e6e6e6`、`red`、`[RGB]178,34,34`）
- `ratex-edit-preview-posframe`：编辑时用 posframe 显示预览并自动更新
- `ratex-auto-download-backend`：是否自动下载 backend
- `ratex-backend-binary`：backend 二进制路径

例如：

```elisp
(setq ratex-backend-root "/path/to/ratex.el/")
(setq ratex-font-size 18.0)
(setq ratex-svg-padding 3.0)
(setq ratex-render-color "#4b5563")
(setq ratex-edit-preview-posframe t)
```

如果你的加载方式比较特殊，自动探测 backend 路径仍然失败，建议直接设置
`ratex-backend-root`。你也可以执行下面的命令查看当前解析到的后端路径：

```elisp
M-x ratex-diagnose-backend-command
```

## 当前状态

这还是一个早期原型。目前主链路已经可用，但仍然有不少可以继续打磨的地方：

- 更懂模式语法的公式检测
- 更稳健的过期响应处理
- 更友好的错误提示
- 面向 MELPA 等包管理器的打包

## 许可证说明

当前仓库包含我们自己的 `ratex.el` 集成代码，以及 `vendor/ratex-core`
这个上游 submodule。上游部分保持其原有许可证和历史。
