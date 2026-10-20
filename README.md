# CodexQuotaBar

A small native macOS menu bar app for your Codex quota. / 原生 macOS Codex 额度菜单栏工具。

```text
5h  ▰▰▰▱▱  66%
7d  ▰▰▰▰▱  80%
```

Shows remaining quota for the short and weekly windows of your ChatGPT account's **Codex usage**. It does not show ChatGPT chat-model message limits or API billing balances. This is an independent community project, not an official OpenAI app.

显示 ChatGPT 账号下的 **Codex 额度**，不包含 ChatGPT 聊天各模型的消息次数或 API 余额。非 OpenAI 官方应用。

## Features / 功能

- Two compact rows for the quota windows; labels follow the server's window durations.
- Green at 70–100% remaining, orange at 20–<70%, red below 20%.
- Click for reset times, last update, manual refresh, remaining/used display and optional launch at login.
- Refreshes about once a minute and after wake. Cached images prevent continuous menu bar redraws.
- Both sides of the bar have 8 pt text spacing; overall width follows the percentage text.
- Failed refreshes retain the last successful in-memory snapshot, with gray bars and a dot indicator.

双行紧凑显示；点击查看详情，可切换剩余/已用并设置登录启动。更新失败会明确标记旧数据。

## Requirements / 环境要求

- macOS 13 or newer.
- Codex CLI installed and signed in with your own ChatGPT account. API-key-only accounts cannot provide this quota.
- To build from source: Xcode Command Line Tools (`xcode-select --install`).

The app checks the CLI bundled with ChatGPT.app / Codex.app, Homebrew locations, then its inherited PATH. A Finder-launched app may have a shorter PATH than your terminal. If discovery fails, install the CLI at a supported location and sign in before retrying.

每个人使用自己的登录状态，项目不附带任何账号或凭证。

## Install / 安装

[Download the latest release / 下载最新版本](https://github.com/Scott0526/CodexQuotaBar/releases/latest) · [Build status / 自动构建](https://github.com/Scott0526/CodexQuotaBar/actions)


### Build locally / 本机构建

Download or clone this repository, open Terminal in its folder, then run:

```sh
git clone https://github.com/Scott0526/CodexQuotaBar.git
cd CodexQuotaBar
chmod +x build.sh
./build.sh
```

Move the resulting `CodexQuotaBar.app` into Applications and open it. Click the menu bar item to enable launch at login if desired. The app does not appear in the Dock.

将生成的 `CodexQuotaBar.app` 移到“应用程序”后打开；点击菜单栏可勾选“登录时启动”。

### Download a build / 下载构建产物

Tagged releases include a universal ZIP for Apple Silicon and Intel Macs, plus a SHA-256 checksum file. The Actions page also provides artifacts from successful builds. These builds are **ad-hoc signed, not Apple-notarized**; macOS may ask you to approve opening the app through System Settings → Privacy & Security. Verify the source and checksum before choosing to open a downloaded build.

发布版及 Actions 构建产物均未经过 Apple 公证；若系统拦截，请在确认来源后通过“系统设置 → 隐私与安全性”中的“仍要打开”处理。也可以选择从源码本机构建。

## Build and check / 构建与校验

```sh
./build.sh --universal
./CodexQuotaBar.app/Contents/MacOS/CodexQuotaBar --self-test
./CodexQuotaBar.app/Contents/MacOS/CodexQuotaBar --render-check /tmp/codex-quota-render.png
# Optional: read your real quota. Requires your own Codex login.
./CodexQuotaBar.app/Contents/MacOS/CodexQuotaBar --probe
```

`--self-test` checks parsing, remaining-percentage conversion and quota-bucket selection. `--render-check` renders 2,000 bitmap variations without querying the network. CI builds both architectures and runs these checks. The Intel slice is cross-compiled; runtime validation is performed on the CI runner's architecture.

## How it works / 数据与隐私

The app launches the locally installed `codex app-server` over stdio, initializes the connection and calls [`account/rateLimits/read`](https://learn.chatgpt.com/docs/app-server). The CLI uses its existing local authentication to contact OpenAI. No model inference or new conversation is started.

The app does not directly read or copy credential files, save quota snapshots to disk, or send data to the project's author. It stores display and onboarding preferences locally. Refresh/render events in the macOS system log contain status messages, not quota values or credentials. `--probe` intentionally prints quota percentages and reset times to your terminal.

只使用本机 Codex CLI 已有登录状态读取额度；不会调用模型，不会向项目作者发送数据。额度仅保存在运行内存中。切换账号后请刷新；读取失败时仍可能显示带错误标记的上次成功数据。到达重置时间后不会自行假定额度已恢复，最终以服务端返回为准。

## Troubleshooting / 常见问题

- **No data:** confirm Codex is signed in with ChatGPT, then click refresh. Reauthenticate in Codex if the login expired.
- **Missing menu item:** open the application from Applications. On a crowded menu bar, macOS may hide items; try freeing menu bar space.
- **Launch at login needs approval:** allow it in System Settings → General → Login Items.
- **Remove:** turn off launch at login, quit the app, then delete it from Applications.

## License

MIT. Contributions and issues are welcome. Do not include tokens, account identifiers or private logs in public issues.
