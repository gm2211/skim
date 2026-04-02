# Skim iOS / iPadOS

Native iOS and iPadOS app for Skim RSS reader with AI-powered triage.

## Requirements

- Xcode 15+
- iOS 17+ / macOS 14+
- [XcodeGen](https://github.com/yonaskolb/XcodeGen) (for generating .xcodeproj)

## Setup

```bash
# Install XcodeGen if needed
brew install xcodegen

# Generate the Xcode project
cd ios
xcodegen generate

# Open in Xcode
open Skim.xcodeproj
```

## Architecture

- **SwiftUI** — declarative UI for iOS, iPadOS, and macOS Catalyst
- **SwiftData** — local persistence (articles, feeds, triage data)
- **FeedKit** — RSS/Atom/JSON feed parsing
- **AIService** — multi-provider AI for triage and summarization (Claude, OpenAI, Ollama)

## Features

- Three-column NavigationSplitView (Sidebar / Article List / Detail)
- Adaptive layout for iPhone, iPad, and Mac
- AI-powered article triage with priority labels
- Reading time tracking and engagement feedback
- Unread/Starred/All filter
- Add feeds by URL
- Pull-to-refresh
