# Contributing to MCP Browser

Thanks for your interest in contributing! This document explains how to get involved.

## Getting Started

1. Fork and clone the repository.
2. Open `MCP Browser.xcodeproj` in Xcode 16 or later.
3. Select the **MCP Browser** scheme and **My Mac** as the run destination.
4. Build and run before making changes to confirm the baseline works.

You don't need any API keys or external accounts to develop on MCP Browser — it only serves MCP tools, it doesn't call out to any LLM provider itself. To exercise the server end-to-end, point an MCP client (Claude Desktop, Codex, etc.) at `http://127.0.0.1:8833/mcp` with the bearer token shown in **Settings → Connection**.

## How to Contribute

### Reporting Bugs

Open an issue and include:

- A clear description of the problem.
- Steps to reproduce it.
- What you expected versus what actually happened.
- macOS version, Xcode version, and which MCP client you're using if relevant.
- Action-log excerpt or `console.app` lines if it's a tool-call failure.

### Suggesting Features

Open an issue with the **enhancement** label. Describe the feature, why it would be useful, and any ideas for how it could work. New tools are a particularly welcome contribution — see `MCP/Tools/` for examples.

### Submitting Code

1. Create a branch from `main`. Use a descriptive name like `fix/dns-rebind-edge-case` or `feature/pdf-form-fill-tool`.
2. Make changes in small, focused commits.
3. Build cleanly with no new warnings.
4. Open a pull request against `main`.

## Adding a new MCP tool

Tools live in [`MCP Browser/MCP/Tools/`](MCP%20Browser/MCP/Tools/). Each tool is a type that conforms to the `MCPTool` protocol — declare its name, description, JSON schema, and an `invoke` body that does the work.

After adding the tool, register it in [`MCP/MCPToolCatalog.swift`](MCP%20Browser/MCP/MCPToolCatalog.swift) so the server advertises it. The next launch surfaces it to clients automatically.

If your tool needs a new piece of host state (e.g. download manager), extend `MCPHost` rather than threading dependencies through call sites.

## Code Style

- Follow standard Swift conventions and the [Swift API Design Guidelines](https://www.swift.org/documentation/api-design-guidelines/).
- Keep MVVM-ish layering: `Storage/` owns persistence, `MCP/` owns the server and tools, `Browser/` owns the WKWebView surface, `Views/` and `Settings/` render.
- Prefer `@Observable` view models and `@Bindable` at the view boundary over `@ObservedObject` / `@StateObject`.
- Use `async`/`await` for asynchronous work.
- Mark MCP-server-touching state `@MainActor` or `nonisolated` deliberately — never accidentally.
- Keep files focused. If a file is growing past ~500 lines, consider splitting it (see how `BrowserTab.swift` is split into `BrowserTab+DOM.swift`, `BrowserTab+Network.swift`, etc.).

## Security-sensitive changes

MCP Browser is a local HTTP server with bearer-token auth and DNS-rebinding defense. Changes to any of:

- `MCP/MCPServer.swift`
- `MCP/MCPSecret.swift`
- The auth, host-header, or origin checks anywhere in the server pipeline

…must be reviewed carefully. If your PR touches these files, please call it out explicitly in the description and explain the threat model implications.

## Commit Messages

Use [Conventional Commits](https://www.conventionalcommits.org/) where it makes sense:

```
feat: add pdf_export tool
fix: reject MCP requests with mismatched Host header
docs: document bearer-token rotation
chore: bump deployment target to macOS 14
```

A short summary on the first line is the most important part. Add a body if the change needs more context.

## Pull Request Guidelines

- Keep PRs focused on a single change.
- Describe what the PR does and why.
- Reference any related issues (e.g. `Closes #12`).
- Make sure the project builds without new warnings.

## Areas Where Help Is Welcome

- Additional MCP tools (form helpers, accessibility queries, advanced screenshot options).
- Multi-window MCP routing — currently the coordinator targets the most-recently-focused window.
- Action-log search and export.
- Accessibility improvements for the tab strip and bookmarks bar.
- Documentation, sample MCP-client configs, and end-to-end demos.

## License

By contributing, you agree that your contributions will be licensed under the [MIT License](LICENSE).
