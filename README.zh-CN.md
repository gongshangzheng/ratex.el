# ratex.el

[English](./README.md)

在 Emacs 里内联预览 LaTeX 数学公式，渲染由上游
[RaTeX](https://github.com/erweixin/RaTeX) 引擎完成。写下 `\(\frac{1}{2}\)`
就能看到公式——不需要安装 TeX，也不需要编译整份文档。

## 演示

![ratex.el demo](./assets/demo.gif)

## 功能特性

- 在 `latex-mode`、`LaTeX-mode`、`org-mode`、`markdown-mode` 中内联预览
- 渲染跟随窗口：只渲染屏幕上可见的公式，滚动时补齐新进入视野的部分，已经
  渲染好的不会重复渲染
- 光标所在的公式保持为可编辑源码；也可以选择在 posframe 或 minibuffer 里
  实时预览
- 渲染在小体积后台进程里异步进行，即使文档有上千个公式，输入和滚动也不卡
- 首次使用时自动下载后端二进制

## 环境要求

- Emacs 29.1 或更新版本
- 首次使用时需要联网，以下载后端二进制

## 安装方式

把 `lisp/` 加入 `load-path`，然后加载：

```elisp
(add-to-list 'load-path "/path/to/ratex.el/lisp")
(require 'ratex)
(global-ratex-mode 1)
```

使用 `use-package`：

```elisp
(use-package ratex
  :load-path "/path/to/ratex.el/lisp"
  :config
  (global-ratex-mode 1))
```

只对当前 buffer 启用可以用 `M-x ratex-mode`。

## 如何使用

默认情况下 `global-ratex-mode` 会在 LaTeX、Org、Markdown buffer 里开启预览。
如果想自己控制：

```elisp
(add-hook 'org-mode-hook #'ratex-mode)
(add-hook 'markdown-mode-hook #'ratex-mode)
(add-hook 'latex-mode-hook #'ratex-mode)
```

Org 文件里可以用关键字覆盖全局设置：

```org
#+ratex: t      # 强制开启
#+ratex: nil    # 强制关闭
```

公式使用 LaTeX 分隔符 `\(...\)` 或 `\[...\]`：

```tex
欧拉恒等式 \(e^{i\pi} + 1 = 0\) 很有名。

\[
\int_0^1 x^2\,dx = \frac{1}{3}
\]
```

不支持美元符号分隔符（`$...$`、`$$...$$`）。已有这类写法可以运行
`M-x ratex-convert-delimiters` 批量转换。

编辑时的行为：

- 窗口内的公式会被渲染；滚动时只渲染新进入视口的部分，已渲染的直接复用
- 光标所在的公式显示为源码（设置 `ratex-edit-preview` 后在 posframe 或
  minibuffer 里显示实时预览），离开后重新渲染
- 代码块里的公式（Org 的 `src` / `example` / `verbatim`、Markdown 围栏代码块）
  以及被转义的分隔符（如 `\\(`）不会被渲染

`\label{eq:...}` 没问题：它没有可见输出，预览会把它去掉再渲染，而 buffer
文本、`org-export` 导出的 LaTeX 仍然保留 label。交叉引用（`\ref`、
`\eqref`）仍然会显示渲染错误，因为单个公式没有文档上下文可以解析它们。

## 命令一览

| 命令 | 作用 |
|---|---|
| `M-x ratex-mode` | 在当前 buffer 开关预览 |
| `M-x global-ratex-mode` | 在所有支持的 buffer 开关预览 |
| `M-x ratex-refresh-previews` | 重新渲染可见区公式 |
| `M-x ratex-render-buffer` | 在后台分块渲染整个 buffer |
| `M-x ratex-cancel-render-buffer` | 取消上述后台渲染 |
| `M-x ratex-convert-delimiters` | 把 `$...$` / `$$...$$` 转成 `\(...\)` / `\[...\]` |
| `M-x ratex-download-backend` | 重新下载后端二进制 |
| `M-x ratex-diagnose-backend` | 显示后端二进制的定位结果 |

## 可配置项

颜色与主题：

- `ratex-dark-render-color` / `ratex-light-render-color`：按当前 frame 的
  明暗自动选择公式颜色（默认 `"white"` / `"black"`）
- `ratex-render-color`：直接指定颜色，忽略主题
- `ratex-dark-posframe-background-color` /
  `ratex-light-posframe-background-color` / `ratex-posframe-background-color`：
  posframe 预览背景色，规则同上
- `ratex-theme-change-refresh-scope`：`all`（默认）/ `current` / `nil`

编辑与渲染：

- `ratex-edit-preview`：`nil`（默认，光标处保持源码）、`posframe` 或
  `minibuffer`
- `ratex-font-size`（默认 `16.0`）、`ratex-svg-padding`（默认 `2.0`）
- `ratex-render-strip-patterns`：渲染前去掉的 LaTeX 命令（这些命令没有可见
  输出），默认只含 `\label`

跟随主题、用 minibuffer 预览的配置示例：

```elisp
(use-package ratex
  :config
  (setq ratex-edit-preview 'minibuffer)
  (setq ratex-dark-render-color "white")
  (setq ratex-light-render-color "black")
  (global-ratex-mode 1))
```

## 疑难排查

- **公式不显示、有 warning**：多半是后端二进制缺失。`M-x ratex-diagnose-backend`
  能看到定位结果，`M-x ratex-download-backend` 可以重新下载。
- **公式里的字形不对／花掉**：没找到 KaTeX 字体，把 `ratex-font-dir` 指向
  仓库附带的 `fonts` 目录。
- **找不到后端位置**：显式设置 `ratex-backend-root` 为仓库路径。

实现细节（后端二进制与 Release 机制、渲染调度、内部旋钮）见
[`docs/internals.md`](./docs/internals.md)。

## 当前状态

可用但仍属早期项目。预览渲染、滚动性能和错误提示已经就位；尚未做的包括
MELPA 之类的打包安装，以及更完整的公式识别覆盖。

## 许可证说明

本仓库包含 `ratex.el` 自身的集成代码，以及作为子模块引入的上游
`vendor/ratex-core`，后者保留其上游许可证与提交历史。
