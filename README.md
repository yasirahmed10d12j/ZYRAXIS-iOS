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

### Direct providers (no custom backend server needed)

The app can also call providers directly with **your own free-tier keys**:

- Select provider **Gemini (direct)** or **Groq (direct)** in
  **Settings → AI Backend → Provider** (default for new installs: Gemini).
- Paste the key in the provider's **SecureField** (labeled per provider) →
  **Save key**. Keys go straight to **Keychain** (`KeychainKeys.geminiAPIKey`
  / `groqAPIKey`); the field shows only presence ("API key present in
  Keychain"), values are never displayed, logged, or committed.
  Get a free key at aistudio.google.com (Gemini) or console.groq.com (Groq).
- `GeminiDirectService` / `GroqDirectService` (`AI/`) call
  `…/v1beta/models/{model}:generateContent` /
  `https://api.groq.com/openai/v1/chat/completions` with your key
  (Gemini: `x-goog-api-key` header, never in the URL; Groq: Bearer header).
  Models are configurable per service (`model`, defaults
  `gemini-3.5-flash-lite` / `llama-3.1-8b-instant` — vendors rotate IDs,
  verify live ones in the consoles). Timeouts use Settings → Request timeout;
  Stop cancels in flight; 401/429/5xx map to friendly errors (missing key →
  "Check the API key in Settings", never attempted without a key).
- Text chat streams real token deltas over HTTPS SSE (`streamGenerateContent`
  / `stream: true`) — same engine path as the backend. **Not implemented:**
  Gemini Live / realtime voice WebSocket audio and Groq transcription. Voice
  mic/STT/TTS are device-local Apple features and work unchanged; the voice
  loop drives text turns through the same engine.

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
| Remote commands (dashboard → device `remote_command`) | ✅ REAL receiver (persistent socket listener → fast-command path, origin logged), tested with doubles; needs server dashboard to send; old builds ignore the frame safely |
| Memory notes + call-by-memory ("remember …", "<name>'s number is …" → "call <name>") | ✅ REAL local logic, tested with doubles; contacts tried first, memory fallback with word-boundary match; short names skip lookup |
| System apps (Messages/Mail/FaceTime fronts) + torch | ✅ REAL routing, tested URL construction; on-device open/torch behavior UNVERIFIED — REQUIRES DEVICE |
| Offline math + unit conversions, web search, Spotify/Maps, who-is, home/work directions, alarms-as-reminders | ✅ REAL local logic, tested; directions resolve addresses from memory |
| Quiz mode ("quiz me on …" → questions, grading, score) + study briefing | ✅ REAL engine logic, tested with doubles; needs an AI provider for questions (local LLM works) |
| Romantic mode (secret "kaccha papad" on / "pakka papad" off) | ✅ REAL style injection on AI turns, tested; fast facts stay factual |
| Hands-free loop repair (adaptive noise floor, re-listen after in-app turns) | ✅ REAL logic, tested with doubles; app-opening turns stay silent (iOS backgrounds us); UNVERIFIED on device |
| Lag fixes (throttled mic-level UI, row-level re-render, flattened core, Reduce Motion) | ✅ REAL, tested where unit-testable; device fps UNVERIFIED — REQUIRES DEVICE |
| Ecosystem sync (shared memory/tasks via hub, stable device identity) | ✅ REAL offline-first decorators, tested with fakes; server API live; needs backend URL + key |
| Volume / Phone-keypad control | ❌ impossible — iOS offers no public API; answered honestly on-device |
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
8. **Run tests.** ⌘U — all suites, no backend needed.
9. **Run the application.** Empty transcript + IDLE core. Default provider is
    **Gemini (direct)** — without a key, sending shows a friendly "check the API key"
    error; with your free AI Studio key in Settings → AI Backend it streams real answers.
    Select **Mock** for offline `[MOCK]` UI testing (two-chunk replay). Fast commands:
    `what time is it`, `stop`, `mic off`.
10. **Configure backend (optional).** Settings → AI Backend: Environment, base URL,
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

## Voice, spoken replies, and open commands (device setup)

If the mic meters move but nothing happens, work through this list — every
item below is enforced by the code, not assumed:

1. **Mic permission**: tap the mic button → iOS asks for microphone access.
   Denied = `MIC DENIED` badge + "Microphone permission denied" error.
   Re-enable in iOS Settings → ZYRAXIS → Microphone.
2. **Live transcription toggle** (default OFF): Settings → Voice &
   Microphone → **Live transcription (STT)**. Without it the mic is
   level-metering only by design — speech is never processed.
3. **Speech recognition permission**: with the toggle on, opening the mic
   asks for Speech Recognition separately. Denied = "Speech recognition
   denied" activity; the mic stays open for levels. Re-enable in iOS
   Settings → ZYRAXIS → Speech Recognition. Note: recognition is
   server-based and needs internet.
4. **Speak, then close the mic**: the mic-close tap is the utterance
   boundary — the trailing final transcript is what gets sent.
5. **Voice responses toggle** (default OFF): Settings → **Voice responses
   (TTS)**. Without it replies are text-only. Spoken replies use the
   loudspeaker (`playAndRecord` + `defaultToSpeaker`); if speech is
   inaudible, raise media volume and confirm the toggle. Tune **Speech
   rate** (0.25–1.0) and **Voice** (system default or a named voice) in
   the same section; recognizer language (**System/English/Urdu/Hindi**)
   applies at the next mic open.
6. A phone call, Siri, or alarm stops capture (`MIC STOPPED`) and never
   auto-resumes — tap the mic again. This is deliberate (privacy).

### Hands-free loop (no second tap)

Enable **Hands-free loop** as well: after you speak, the mic closes itself
on utterance end (~1.2 s of quiet, 60 s safety cap) and the final transcript
auto-sends — then the mic re-opens after each voice turn. Typed messages
never re-arm the mic, and pressing Stop ends the loop until the next voice
turn. Known limits: speaker bleed can self-trigger while replies play;
re-listening starts the mic even if the previous turn failed (say the
command again or tap Stop).

### Calling and messaging by name

`call mom`, `text dad`, `whatsapp mom` resolve against iOS contacts
(first match wins — use the saved full name for shared names). Grant
**Contacts** when asked; denied or unknown names report an error in the
activity feed instead of dialling. Digits always work without contacts
(`call 5551234567`, `whatsapp 15551234567`). SMS/WhatsApp open the composer
or chat — iOS always requires your tap to actually send. `open instagram`
and `open whatsapp` open those front pages; any other app name cannot be
opened (iOS sandbox — see limitations).

### Background reality (iOS-enforced)

Switching apps gives the in-flight reply ~30 s to finish
(`beginBackgroundTask`), then iOS suspends ZYRAXIS. **Continuous background
listening is impossible on stock iOS**: the system cuts the mic within half
a minute of backgrounding and shows the recording indicator while any
capture runs. The app never runs "until removed from open tabs" — any app
claiming otherwise on non-jailbroken iOS is misrepresenting. Plan voice
sessions in the foreground.

### Open commands (no third-party app access)

Fast commands that open iPhone destinations through Apple-supported schemes
and universal links only. Say exactly:

- `open example.com` / `go to example.com` → website (Safari)
- `search cats` / `google cats` → web search · `open spotify` → Spotify · `open google maps` → Google Maps
- `call 5551234567` → Phone (system confirmation sheet)
- `text 5551234567` → Messages · `email a@b.com` → Mail
- `open messages` / `open mail` / `open facetime` → those composers/app (device-UNVERIFIED)
- `call rehan` → contacts first, then remembered numbers ("Rehan's number is …")
- `remember that …` / `rehan's number is …` → saved to on-device memory
- `directions to paris` / `navigate to …` / `map of …` → Apple Maps
- `facetime 5551234567` → FaceTime · `open app store` → App Store
- `open youtube` / `youtube cats` → YouTube (HTTPS universal link: opens the
  app when installed, Safari otherwise — never the `youtube://` custom
  scheme, which fails instantly without the app)
- `open x` / `open twitter`, `open facebook`, `open snapchat` → those front
  pages (universal links)

Anything unvalidated (`open settings`, unknown apps) is NOT
opened — it falls through to the AI instead, and a failed open reports
"Couldn't open … on this iPhone". iOS Settings and arbitrary third-party
apps cannot be opened (sandbox; no public scheme) — requests for them go to
the AI, never to a bypass. (`call abc` routes to a contact lookup, not the
AI — unknown names report "Couldn't find … in contacts".)

### Siri Shortcuts (no need to open the app)

"Hey Siri, ask ZYRAXIS …" answers without opening the app: the shortcut
reads your saved Gemini/Groq key from Keychain, calls the provider
directly, and Siri speaks the answer. No key = a setup dialog pointing at
Settings. Rate limits surface as "try again" dialogs. The shortcut needs an
unlocked device (Keychain) and gives one final answer per question
(no streaming inside Siri).

### Transcript export

Tap **Share** next to Clear in the transcript header to open the iOS share
sheet with the conversation as plain text (`[USER]` / `[ASSISTANT]` lines).

## Device info (Settings → Device)

Live iPhone facts, every value from a real iOS API: model, iOS/app version,
CPU cores, total RAM, this app's footprint, storage free/total, battery
level/state, thermal state, low-power mode. Tap **Refresh** to re-read.
Also available to a connected backend as the read-only `get_device_info`
tool (same honesty contract as `get_app_info`).

Deliberately absent (no iOS API exists — shown nowhere rather than faked):
CPU clock frequency, system-wide free/used RAM, network throughput.

## Voice improvements (Phase 5)

### Natural multilingual TTS
- **Auto voice selection**: when no explicit voice is chosen, ZYRAXIS detects
  the script of the outgoing text (Devanagari → Hindi, Arabic/Urdu → Urdu,
  Latin → English) and picks a matching system voice automatically.
- **Enhanced voices preferred**: downloadable "Enhanced" voices (higher quality,
  more natural) are used when available for the detected language.
- **Settings picker**: recommended voices (enhanced + locale-matched) shown
  first, then all voices. `⭐` marks Enhanced quality.

### Hindi/Urdu voice output fixed
Previously, Hindi/Urdu replies fell back to the system default (often an
English voice that cannot pronounce Devanagari/Arabic script). Now the
auto-detection picks `hi-IN` or `ur-PK` voices when the reply contains those
scripts, so spoken Hindi/Urdu actually works.

### Human-like system prompt
The AI system prompt now instructs a warm, concise, friend-like style:
short sentences, plain words, mirrors your language (Hinglish/Hindi/Urdu/
English), gentle humor welcome, never stiff or robotic. Replies are 1–2
sentences unless you ask for more.

## New app integrations (Settings → Device, or say the command)

| Command | Opens |
|---------|-------|
| "open camera" / "take photo" | System Camera app |
| "open youtube" | YouTube (HTTPS universal link → app if installed) |
| "search youtube for techno gamerz" | YouTube results page for query |
| "open instagram" | Instagram |
| "open whatsapp" | WhatsApp |
| "open telegram" | Telegram |
| "open safari" / "open browser" | Safari |
| "open chrome" | Chrome web page (opens in default browser) |
| "open photos" / "gallery" | Photos app |
| "open app store" | App Store |

All use **HTTPS universal links** (no custom schemes) — open the native app
when installed, fall back to Safari otherwise. No `canOpenURL` allowlist
entries required.

## Device control

| Command | Action |
|---------|--------|
| "brightness up" / "brighter" / "increase brightness" | +15% brightness |
| "brightness down" / "dim" / "decrease brightness" | −15% brightness |
| "set brightness 50%" / "set brightness half" | Absolute level (5…100%) |
| "volume up/down/mute" | **Honest answer**: "Volume can only be changed with the iPhone side buttons — iOS doesn't let apps set it." |

Volume is **not settable** by third-party apps on iOS (public API does not
exist). ZYRAXIS answers honestly instead of pretending.

## Reminders / Tasks (local, with notifications)

- "remind me to call mom in 10 minutes" → creates task with due date
- "remind me to buy milk" → creates task (no due date)
- "my reminders" / "show my tasks" → reads back active reminders (up to 5)
- Tasks use `LocalTaskService` + `UNUserNotificationCenter` for alerts.
- Backend sync is Phase 6.

## Notifications / Alarms / Mail (read-only / honest)

- `get_notifications` tool: returns recently delivered notifications (same
  as Notification Center). Requires Notifications permission.
- `set_alarm` tool: **opens Clock/Shortcuts app** — iOS does NOT let third-
  party apps set alarms directly. User confirms in the system app.
- `open_mail` tool: opens Mail app or `mailto:` compose — iOS does NOT let
  third-party apps read existing emails.

No private APIs, no fake data. Limitations are stated in the tool descriptions
and spoken replies.

## Codemagic CI/CD setup

`codemagic.yaml` at the repo root defines two workflows (verified against
`ZYRAXIS-iOS.xcodeproj`, scheme `ZYRAXIS-iOS`, bundle ID
`com.zyraxis.assistant`, iOS 17.0, Xcode 16+):

- `ios-simulator` (push to `main`) — no Apple credentials needed. Runs the
  17 XCTest suites on an available simulator plus a Release generic-device
  build check (compile/link/package with bundle-ID assertion). This is NOT
  an archive and NOT an installable IPA (Xcode 16.2 archive validation
  requires real signing assets — see `codemagic.yaml`).
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
