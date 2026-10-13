# ZYRAXIS iOS — Adaptive Reasoning & Execution Intelligence System

Native iOS personal AI assistant for **iPhone 11 Pro Max**, written in **Swift + SwiftUI**
with Swift Concurrency. Current version: **0.5.0-phase5**.

Phase rule (all phases): **no fake features**. Anything not runnable in the
current environment is marked UNVERIFIED with its blocker — never claimed.

> Separate project. Does not touch `ZYRAXIS Desktop` or `ZYRAXIS Android`
> (on this machine: `JARVIS-Desktop` / `JARVIS-Android` — both left untouched).

---

## 1. Purpose

A serious, premium, futuristic assistant — not a generic chatbot:

- dark futuristic interface (black/charcoal + cyan/blue glow, glass panels)
- animated central ZYRAXIS core reacting to assistant + mic state
- conversation transcript as a technical log
- command input + mic + settings + connection + activity feed

Phase 1 rule: **no fake features**. Mic levels are real, permission flows are
real, networking errors are structured, and the mock AI is always labeled
`[MOCK]`. Speech-to-text, backend AI, tool execution, and Vision processing
are interfaces only.

## 2. Architecture

Strict layering (top → bottom):

```
UI (SwiftUI views)
  ↓ observes
Assistant State (AssistantStateMachine, @MainActor ObservableObject)
  ↓ drives
AI / Conversation Layer (AIService protocol, AIContext, MockAIService)
  ↓ may request
Agent / Tool Layer (AgentTool, ToolRegistry / DefaultToolRegistry)
  ↓ calls
Backend / API Layer (APIClient, WebSocketManager, BackendConfig)
```

Cross-cutting: `MemoryService`, `TaskService`, `KeychainService`,
`NotificationService`, `VoiceManager`, `VisionService`, `SettingsStore`.

Every layer is a **protocol** so phases swap implementations without touching
views. `AppDependencies` (injected as `EnvironmentObject`) is the composition
root — see `ZYRAXIS/App/AppDependencies.swift`.

### Assistant state machine

```
IDLE → LISTENING → USER_SPEAKING → PROCESSING → SPEAKING → IDLE
IDLE → PROCESSING / EXECUTING / VISION
PROCESSING → EXECUTING → (PROCESSING | SPEAKING | IDLE)
* → ERROR → IDLE (sticky until reset)
```

Full matrix in `Core/AssistantStateMachine.swift`, covered by
`ZYRAXISTests/AssistantStateMachineTests.swift`.

## 3. Folder structure

```
ZYRAXIS-iOS/
├── ZYRAXIS/
│   ├── App/            ZYRAXISApp.swift, AppConfig.swift, AppDependencies.swift
│   ├── Core/           AssistantState.swift, AssistantStateMachine.swift, AppError.swift
│   ├── Models/         ConversationMessage.swift, AssistantActivity.swift
│   ├── Theme/          ZyraxisTheme.swift (colors, fonts, panel style)
│   ├── Components/     ZyraxisCoreView.swift, GlassPanel.swift, MicButton.swift,
│   │                   ConnectionBadge.swift, ActivityRow.swift
│   ├── UI/             MainAssistantView.swift, ConversationTranscriptView.swift,
│   │                   CommandInputBar.swift, SettingsView.swift
│   ├── AI/             AIService.swift (protocol + context/response/stream),
│   │                   MockAIService.swift (labeled mock, UI dev only)
│   ├── Voice/          VoiceState.swift, VoiceManager.swift (real AVAudioSession
│   │                   + engine tap level metering; NO STT yet)
│   ├── Vision/         VisionService.swift (permission real, analyze() stub)
│   ├── Networking/     APIClient.swift, WebSocketManager.swift (+reconnect),
│   │                   NetworkError.swift, ConnectionState.swift, BackendConfig.swift
│   ├── Memory/         MemoryItem.swift, MemoryService.swift, InMemoryMemoryService.swift
│   ├── Tasks/          ZyraxisTask.swift, TaskService.swift, LocalTaskService.swift
│   ├── Tools/          ToolRegistry.swift (AgentTool protocol + default registry)
│   ├── Services/       SettingsStore.swift, NotificationService.swift
│   ├── Security/       KeychainService.swift (SystemKeychainService, KeychainKeys)
│   └── Resources/      Info.plist (mic/camera/speech strings)
├── ZYRAXISTests/       6 XCTest files (state, tasks, network, memory, settings, voice)
├── README.md
└── .gitignore
```

## 4. Windows development workflow (current)

You are authoring on **Windows**. Xcode and Swift toolchains do not run here,
so:

- Edit Swift files in any editor (VS Code, etc.).
- Keep file/folder names exactly as created — Xcode picks them up by reference.
- Do NOT expect `swift build`, simulators, or `xcodebuild` to work on Windows.
- Static checks possible on Windows: file inventory, UTF-8/BOM checks,
  balanced-brace heuristic, `Info.plist` XML well-formedness, line-ending audit.
- Commit with git from Windows normally; build on macOS.

## 5. Run ZYRAXIS on iPhone from a new Mac (10 minutes)

The folder ships a real, ready-to-open Xcode project — no manual target setup.

**STEP 1 — Copy the folder to the Mac.**
Copy the entire `ZYRAXIS-iOS` folder (USB, shared folder, or git).
Then on the Mac: `chmod +x Scripts/*.sh` (Windows cannot store that bit).

**STEP 2 — Open `ZYRAXIS-iOS.xcodeproj`.**
Double-click it (or `open ZYRAXIS-iOS.xcodeproj`). Targets already exist:
`ZYRAXIS-iOS` (app, 54 Swift files + assets) and `ZYRAXISTests` (17 files).
Bundle ID: `com.zyraxis.assistant` (change it in Xcode → target →
Signing & Capabilities; it lives in one place, nowhere else).
Deployment target iOS 17.0, iPhone only, Swift 5, zero dependencies.

**STEP 3 — Signing & Capabilities.**
Enable **Automatically manage signing**, select your Apple Account/Team.

**STEP 4 — Connect the iPhone.**
Plug it in, unlock it, Trust the Mac if prompted, enable Developer Mode
on the iPhone if iOS asks (Settings → Privacy & Security).

**STEP 5 — Select the `ZYRAXIS-iOS` scheme** (shared scheme ships in the
project — no setup needed).

**STEP 6 — Select the connected iPhone** as run destination
(or iPhone 11 Pro Max simulator for UI-only testing).

**STEP 7 — Press Run ▶** (⌘R). First build takes a minute.

**STEP 8 — Follow Xcode's normal automatic-signing flow** if it asks to
register the device.

> IMPORTANT: the source folder is portable, but Apple signing credentials,
> certificates, provisioning profiles, and device registration are
> account/Mac specific and are NOT bundled — copying the folder alone does
> not bypass signing. Never commit `.p12`, `.mobileprovision`, or team IDs.

**Project notes (why it is shaped this way).**
- Target is named `ZYRAXIS-iOS`, but `PRODUCT_MODULE_NAME = ZYRAXIS` keeps the
  Swift module stable — all 17 test files' `@testable import ZYRAXIS` work
  unchanged, with zero Swift edits for packaging.
- Groups mirror physical folders (`App/`, `Core/`, `AI/`, …); nothing flattened.
- `Config/Shared.xcconfig` holds non-secret base settings (deployment target,
  Swift version, signing style); Debug/Release add diagnostics level + an
  informational backend-env marker. No secrets in any xcconfig, ever.
- No entitlements file: mic/camera/speech/notifications need only the
  `Info.plist` usage strings. No `.xcworkspace`, no SPM packages.

**One-command validation** (from the project root on the Mac):
`./Scripts/verify-mac.sh` — 10 read-only checks (macOS, Xcode, project,
scheme, SDK, signing config, no Windows paths). It prints
`ALL CHECKS PASSED` only if every check actually passed.
`DEVICE_UDID=<udid> ./Scripts/build-device.sh` (or `DEVICE_NAME=...`) —
device-config build; without a device it builds `generic/platform=iOS`
and says so honestly instead of pretending an install succeeded.

*Fallback (only if the shipped project ever fails to open): create a blank
iOS App target and File → Add Files the `ZYRAXIS/` + `ZYRAXISTests/` folders
per the Debug/Release xcconfigs in `Config/`. Requirements stay: Xcode 16+,
iOS 17 SDK+, an Apple ID/team.*

No third-party dependencies — **no `pod install`, no SPM packages**.

## 6. Backend integration (Phase 2 — implemented client side)

The iPhone app is the **client**. Provider credentials, model calls, and tool
execution live server-side. The app only presents the user's own backend key
(Keychain → `Authorization: Bearer`, never logged, never in source).

- Set **Settings → AI Backend → Environment + base URL** (`https://…`) and
  **WebSocket URL** (`wss://…`). Dev URLs override when Environment =
  Development. Stored in `UserDefaults` via `SettingsStore`; validated by
  `BackendConfig.parse*` (empty = unconfigured).
- Paste the API key in **Settings → Backend API key** — goes straight to
  **Keychain** (`KeychainKeys.backendAPIKey`).
- Select provider **ZYRAXIS Backend**. `BackendAIService` then streams over
  the socket; without a configured backend the UI shows a friendly
  "not configured" error instead of attempting network I/O.

### Wire protocol (v1, see `Networking/BackendProtocol.swift`)

Every frame is `{version, type, requestId, payload}`. Types: `session_start`,
`session_end`, `user_message`, `assistant_delta` (with per-request `seq`),
`assistant_complete`, `assistant_error`, `tool_call`, `tool_result`, `ping`,
`pong`. Unknown types are tolerated + ignored; version mismatches surface as
a friendly error. `ZyraxisV1Adapter` maps envelopes to `AIStreamEvent`s — a
different server contract needs a new adapter, not engine changes.

Non-streaming fallback: `POST {baseURL}/api/{apiVersion}/chat`
`{requestId, text, context}` → `{text, toolCalls?, requestId?}`.

### What the server must implement (minimum)

1. Accept the WS connection, read `session_start` + `user_message`.
2. Stream `assistant_delta` frames (`seq` 1-based per request), then
   `assistant_complete` (full text + tool calls). Tools execute server-side;
   findings return as `tool_result` frames.
3. Errors as `assistant_error {code, message, retryable}`.
4. Answer `ping` with `pong` (client also pings every 30s).

## 7. What is REAL vs NOT YET (honest inventory)

| Area | Phase 2 status |
|---|---|
| Assistant state machine + UI reactivity | ✅ REAL, tested (matrix preserved) |
| Dark futuristic UI, core animation, transcript, settings | ✅ REAL SwiftUI + streaming deltas + Stop button |
| Streaming conversation engine (request IDs, dedup, stale-guard, cancel) | ✅ REAL client logic, tested with scripted service; needs live backend for E2E |
| Versioned WS protocol + adapter | ✅ REAL client side, tested; server must implement §6 contract |
| HTTP chat fallback + Keychain Bearer auth | ✅ REAL client side; needs live backend for E2E |
| Mic permission, AVAudioSession config, start/stop, interruption handling, live RMS level | ✅ REAL (AVFoundation) |
| Fast commands (time/date/stop/mic on/off, exact-match only) | ✅ REAL on-device facts; anything else goes to AI |
| Speech-to-text / transcription | ✅ REAL Apple Speech provider (opt-in, partials+finals), UNVERIFIED — REQUIRES XCODE/DEVICE |
| TTS / speaking audio | ✅ REAL AVSpeechSynthesizer provider (opt-in), UNVERIFIED — REQUIRES XCODE/DEVICE |
| HTTP client (timeout, cancel, structured errors, reconnect WS + ping) | ✅ REAL, tested |
| Tool execution on device | ❌ NOT implemented (metadata only; backend executes server-side) |
| Tool round-trip client side (lookup → safe read-only exec → result/refusal) | ✅ REAL client logic, tested with doubles; zero tools registered |
| Connection diagnostics + T0…T4 latency | ✅ REAL values or "—" (DEBUG section, no fake metrics) |
| Dev/Staging/Production environments | ✅ REAL URL resolution with production fallback |
| Memory CRUD (in-memory) + bounded context injection | ✅ REAL, tested; backend sync later |
| Tasks CRUD + snooze + local notifications | ✅ REAL (+ best-effort UN scheduling) |
| Keychain save/load/delete | ✅ REAL (Security.framework) |
| Camera permission | ✅ REAL; Vision analyze() throws `processingUnavailable` |
| Continuous camera frame processing | ❌ explicitly out of scope |
| Unit tests | ✅ 17 suites (run with ⌘U on macOS) |

## 8. Testing

On macOS: **⌘U** or `xcodebuild test -scheme ZYRAXIS -destination 'platform=iOS Simulator,name=iPhone 11 Pro Max'`.

Suites: assistant state transitions, task model/service, network errors +
`BackendConfig` parsing + request building, memory model/service, settings
defaults/persistence, voice-state contracts (hardware-free by design),
protocol envelope round-trip/version/unknown-type tolerance, streaming
accumulation/ordering/dedup/cancellation/stale-guard via scripted service,
context limits + secret-memory filtering, fast-command routing, reconnect
backoff determinism, user-friendly error mapping + log redaction, tool
round-trip (safe exec / unsupported / refusal), engine memory round-trip
(bounded, filtered, disabled), request timing + URL sanitization,
environment (dev/staging/prod) resolution. No suite needs a live
backend. E2E against a real server is unverified (no backend available).

## 9. Version

`0.5.0-phase5` — portable `.xcodeproj` + scheme + xcconfigs + scripts.
See §11–§12 for what is verified vs explicitly unverified.

## 12. Phase 6 — validation status (Windows environment)

Phase 6 ran on Windows (no Xcode/Swift/SDKs/devices), so every item needing
those is UNVERIFIED with its blocker — nothing is claimed as tested:
- Environment: Windows 11 x64, no xcodebuild/swift/xcrun (verified absent).
- Build/tests/simulator/iPhone/mic/STT/TTS/backend/E2E: all UNVERIFIED —
  REQUIRES XCODE / DEVICE / BACKEND / USER ACTION as applicable.
- Regression re-verified statically: shipped validator passes 19/19
  (54 prod + 17 test files mapped, bundle IDs, automatic signing, scheme
  with all 6 actions, xcconfig chain, plist keys, assets, single @main,
  no JARVIS refs, no Windows runtime paths, no secrets).
- Security re-swept: no credential values; only key names, policy comments,
  redaction patterns, and clearly-fake test fixtures. No TLS bypass, no ATS
  exceptions, no shell execution anywhere.
- Sibling projects untouched (see final report).

## 10. Phase 3 — first Xcode build checklist (macOS Sequoia + Xcode 16)

(unchanged — steps 1–14 as before; Phase 4 extends them below)

## 11. Phase 4 — validation status (honest)

Authored on Windows (no Xcode, no iPhone, no backend, no microphone), so
everything below that needs those is marked UNVERIFIED with its blocker.
Code is written for strict (Swift 6) concurrency throughout — weak captures,
static helpers, Sendable sample bridges, no `@unchecked Sendable` anywhere.

### New in Phase 4 (implemented, static-checked, UNVERIFIED — REQUIRES XCODE)
- `AppleSpeechTranscriber` (Apple Speech framework, live-buffer STT with
  partials + finals, graceful stop, resource release) behind `STTProvider`.
- `AVSpeechService` (AVSpeechSynthesizer: speak/stop/pause/resume, no
  overlapping speech, bounded completion watchdog) behind `SpeechService`.
- Voice loop wiring: mic tap → copied samples → STT → finals auto-send via
  `acceptExternalTranscript`; TTS speaks replies only when
  Settings → Voice responses is ON (default OFF); cancel/new-request always
  stops speech (no post-cancel speech). Live transcription is opt-in
  (default OFF); mic stays level-only otherwise.
- Safe E2E tool `get_app_info` (read-only app identity, seeded in registry).
  No destructive tools exist or may be added to this client.
- SettingsStore persistence fix: mutations now honor the injected
  UserDefaults (proven by `SettingsPersistenceTests`).
- Info.plist trimmed: unjustified `UIBackgroundModes` removed; usage strings
  updated for real STT. No entitlements required (mic/camera/speech/notifications
  need only usage strings). No signing credentials in the repo.

### Permissions to grant on device (UNVERIFIED — REQUIRES USER ACTION)
Microphone, Speech Recognition (both prompted on use + Settings buttons),
Notifications (task reminders). Camera stays permission-only.

### E2E / device matrix (all UNVERIFIED — REQUIRES XCODE / DEVICE / BACKEND)
Xcode build, all 17 XCTest suites, simulator launch, iPhone 11 Pro Max
install/launch/debugger, mic start/stop/interruption cycle, STT partials +
finals, TTS speak/stop/pause, voice-loop duplication/staleness behavior,
HTTP POST + WS streaming + cancel + tool_call/get_app_info round-trip +
memory round-trip against a live backend, timing metrics, resource audit
(start→stop→start accumulation), keyboard/scroll/Dynamic Type checks.

### Known limitations (real)
- Speaker→mic bleed at high TTS volume can self-transcribe (no echo gate).
- STT is server-based (network); on-device mode not implemented.
- TTS completion is watchdog-detected (no delegate object by design).
- No `.xcodeproj` is shipped (hand-written ones are fragile — use §5 steps).
- E2E timing numbers cannot be reported until a live backend exists.

## 10. Phase 3 — first Xcode build checklist (macOS Sequoia + Xcode 16)

Do steps in order. Stop and fix at the first failure — do not skip ahead.

1. **Open Xcode.** Copy/clone `ZYRAXIS-iOS` to the Mac (Steps §5.1–2).
2. **Create/import project.** File → New → Project → iOS → App,
   Product Name `ZYRAXIS`, Interface SwiftUI, Language Swift,
   Bundle ID `com.zyraxis.ios` (or your own), **iOS 17.0** minimum.
3. **Add source folders.** File → Add Files to ZYRAXIS… → select `ZYRAXIS/`
   (one group, app target checked). Repeat for `ZYRAXISTests/` after step 4.
4. **Configure target.** Target → General: same bundle ID, iOS 17.0,
   iPhone orientation Portrait. Build Settings: Swift Language Mode —
   the code is written for **both Swift 5 and Swift 6 modes** (§3 fixes);
   confirm `SWIFT_VERSION`/`SWIFT_DEFAULT_ACTOR_ISOLATION` as you prefer.
   Verify Debug → Active Compilation Conditions contains **DEBUG**
   (drives the `#if DEBUG` diagnostics section in Settings).
5. **Configure signing.** Target → Signing & Capabilities → Team
   (free Apple ID = simulator + direct install; paid = distribution).
6. **Select iPhone simulator.** Scheme destination **iPhone 11 Pro Max**
   (or any iOS 17+ simulator).
7. **Build.** ⌘B. Expected: zero errors. If concurrency errors appear,
   they will point at Task captures — the code uses `[weak …]` + static
   helpers throughout; do not silence with `@unchecked Sendable`.
8. **Run tests.** ⌘U — all 16 suites, no backend needed.
9. **Run the application.** Empty transcript + IDLE core + "NO BACKEND"
   badge (mock provider default). Type a message → `[MOCK]` reply streams
   in two chunks. Fast commands: `what time is it`, `stop`, `mic off`.
10. **Configure backend.** Settings → AI Backend: Environment, base URL,
    `wss://` URL, Keychain API key. Provider → ZYRAXIS Backend.
11. **Test WebSocket.** Settings → Connection → Connect; badge goes
    ONLINE; DEBUG diagnostics show host, reconnects, ping round-trip.
12. **Test streaming.** Send a message; text must appear incrementally
    (STREAMING indicator), single assistant bubble, no duplicates.
13. **Test cancellation.** Press Stop mid-stream → idle, partial text kept,
    no further updates (stale-guard).
14. **Test tool round-trip.** Have the server send `tool_call` for an
    unregistered tool → activity "Unsupported tool" + structured
    `tool_result` error back; register a read-only tool later to verify
    the execution path (no destructive tools, ever, on this client).

## Codemagic CI/CD setup

`codemagic.yaml` at the repo root defines two workflows (verified against
`ZYRAXIS-iOS.xcodeproj`, scheme `ZYRAXIS-iOS`, bundle ID
`com.zyraxis.assistant`, iOS 17.0, Xcode 16+):

- `ios-simulator` (push to `main`) — no Apple credentials needed. Runs the
  17 XCTest suites on an available simulator and produces an **unsigned**
  Release archive as a compile check. This is NOT an installable IPA.
- `ios-release-ipa` (tag `v*`) — **signed** IPA via automatic signing.
  Requires the setup below; fails fast with a clear message until then.

Connect repo: Codemagic → Add application → GitHub →
`yasirahmed10d12j/ZYRAXIS-iOS` → Project type "iOS App" → the workflows are
read from `codemagic.yaml` automatically. Start with `ios-simulator`.

Signing setup for `ios-release-ipa` (all in Codemagic UI, never in the repo):

1. Codemagic → Teams → code signing identities → add your Apple Distribution
   certificate (`CERTIFICATE_PRIVATE_KEY`).
2. Codemagic → App Store Connect integration → add the API key (provides
   `APP_STORE_CONNECT_ISSUER_ID`, `APP_STORE_CONNECT_KEY_IDENTIFIER`,
   `APP_STORE_CONNECT_PRIVATE_KEY`).
3. Apple Developer Portal → register bundle ID `com.zyraxis.assistant`.
4. Push a tag (`v0.5.0`) to trigger the signed build; the IPA appears under
   build artifacts (`build/ipa/*.ipa`).

No commit/push is done by CI. Validation status: YAML statically checked
(no Tabs, cross-checked paths/scheme/bundle ID); no Codemagic cloud build has
been run yet, so no IPA has been built or signed.
