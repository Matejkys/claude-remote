# Claude Remote - SDK Refactor Plan

## Executive Summary

Refactor from hook-based notification system to SDK-based approach to enable full support for `AskUserQuestion` and other interactive prompts that are not available through Claude Code hooks.

**Current State:** Hook-based (notify-hook.sh → HTTP listener → Telegram)
**Target State:** SDK-based (canUseTool callbacks → WebSocket → Telegram)
**Primary Goal:** Support AskUserQuestion notifications when user is away

---

## 1. Current Architecture Analysis

### 1.1 Current Flow
```
Claude Code (CLI)
  ↓ (hooks: Stop, Notification)
notify-hook.sh
  ↓ (HTTP POST with JSON)
ClaudeRemote App (Swift)
  ↓ (NotificationRouter)
TelegramService → Telegram Bot API
  ↓
Telegram User
  ↓ (inline buttons)
telegram-relay (Node.js)
  ↓ (tmux send-keys)
Claude Code (CLI)
```

### 1.2 Current Components

**Swift App (ClaudeRemote):**
- HTTPListener (port 7677)
- NotificationRouter (away/present logic)
- TelegramService (send notifications)
- LocalNotifier (macOS notifications)
- PresenceDetector (away detection)

**Node.js Bot (telegram-relay):**
- Telegram bot (grammy)
- tmux integration (sendKeys, capturePane)
- Inline keyboard for pane selection
- Message routing

**Hook Script (notify-hook.sh):**
- Captures stdin from Claude Code
- Enriches with tmux context
- POSTs to HTTP listener

### 1.3 Current Limitations

❌ **No AskUserQuestion support** - hooks don't fire for questions
❌ **No tool permission interception** - can't programmatically approve/deny
❌ **One-way communication** - hooks can't respond back to Claude Code
❌ **Limited context** - only what's in hook JSON payload

---

## 2. Target SDK Architecture

### 2.1 Target Flow
```
Claude Agent SDK (TypeScript/Python)
  ↓ (canUseTool callback)
SDK Bridge Server
  ↓ (WebSocket)
ClaudeRemote App (Swift) OR Direct WebSocket Client
  ↓ (NotificationRouter)
TelegramService → Telegram Bot API
  ↓
Telegram User (receives notification)
  ↓ (inline buttons - approve/deny/answer)
telegram-relay (Node.js)
  ↓ (WebSocket response)
SDK Bridge Server
  ↓ (resolves Promise)
Claude Agent SDK (continues execution)
```

### 2.2 New Components

**SDK Bridge Server (Node.js/TypeScript):**
- Wraps Claude Agent SDK
- WebSocket server for bidirectional communication
- Session management (active sessions, pending approvals)
- State persistence (reconnection handling)
- Tool permission gating via `canUseTool()`

**Updated telegram-relay:**
- WebSocket client (connects to SDK Bridge)
- Sends approval/denial/answers back via WebSocket
- Enhanced UI for questions (not just permissions)

**Optional: Updated ClaudeRemote App:**
- WebSocket client instead of HTTP server
- Bidirectional communication support
- OR: Remove Swift app entirely, move logic to Node.js

### 2.3 New Capabilities

✅ **AskUserQuestion support** - intercept via `canUseTool("AskUserQuestion")`
✅ **Tool permission control** - programmatic approve/deny
✅ **Bidirectional communication** - responses flow back to SDK
✅ **Rich context** - full tool input/output visibility
✅ **State recovery** - reconnection preserves pending actions
✅ **Session isolation** - multiple concurrent Claude sessions

---

## 3. Implementation Phases

### Phase 1: Proof of Concept (Week 1-2)
**Goal:** Validate SDK integration, basic permission gating

**Tasks:**
1. Setup Claude Agent SDK in new `sdk-bridge/` directory
   - Choose TypeScript (matches telegram-relay)
   - Install `@anthropic-ai/claude-agent-sdk`
2. Implement minimal `canUseTool()` callback
   - Log all tool calls
   - Test with simple session
3. Add WebSocket server (ws package)
   - Broadcast tool permission requests
   - Accept approve/deny responses
4. Create test client (Node.js script)
   - Connect to WebSocket
   - Manually approve/deny tools
5. Validate AskUserQuestion interception
   - Create test prompt with questions
   - Verify callback fires

**Success Criteria:**
- SDK runs Claude session
- `canUseTool()` fires for all tools
- WebSocket client can approve/deny
- AskUserQuestion intercepted

**Files Created:**
```
sdk-bridge/
├── package.json
├── tsconfig.json
├── src/
│   ├── index.ts          # Main entry point
│   ├── sdk-wrapper.ts    # SDK session management
│   ├── websocket.ts      # WebSocket server
│   └── types.ts          # TypeScript interfaces
└── test-client.js        # Manual testing client
```

---

### Phase 2: Integration with Telegram Bot (Week 3-4)
**Goal:** telegram-relay connects to SDK Bridge, sends Telegram notifications

**Tasks:**
1. Add WebSocket client to telegram-relay
   - Connect to SDK Bridge on startup
   - Handle reconnection logic
2. Modify bot.ts to handle WebSocket events
   - `permission_request` → send Telegram notification
   - `ask_user` → send Telegram notification with question
   - User clicks inline button → send WebSocket response
3. Update notification format
   - Include `requestId` for matching responses
   - Session context (project, cwd)
4. Add response handlers
   - `permission_response` event
   - `ask_user_response` event
5. Test end-to-end flow
   - Run SDK session → permission prompt → Telegram → approve → SDK continues

**Success Criteria:**
- telegram-relay receives WebSocket events
- Telegram notifications sent correctly
- Inline button responses reach SDK
- Session continues after approval

**Files Modified:**
```
telegram-relay/
├── src/
│   ├── bot.ts            # Add WebSocket client
│   ├── websocket-client.ts  # NEW: WebSocket connection manager
│   └── types.ts          # Add SDK event types
```

---

### Phase 3: Replace ClaudeRemote App OR Keep Hybrid (Week 5-6)
**Goal:** Decide architecture for away detection and routing

**Option A: Remove Swift App (Simpler)**
- Move presence detection to SDK Bridge
- Use system idle time (iokit on macOS)
- Direct Telegram routing from SDK Bridge

**Option B: Keep Swift App (Better UX)**
- Swift app remains for:
  - Menu bar presence
  - Away detection UI
  - Local macOS notifications (when present)
- SDK Bridge sends to ClaudeRemote via WebSocket
- ClaudeRemote routes (local vs Telegram)

**Recommendation:** Option B (keep Swift app)

**Tasks (Option B):**
1. Add WebSocket client to ClaudeRemote (Swift)
   - Replace HTTPListener with WebSocket connection
   - Connect to SDK Bridge on startup
2. Update NotificationRouter
   - Receive events via WebSocket instead of HTTP
   - Same away/present routing logic
3. Add response sending
   - Bidirectional WebSocket communication
   - Forward Telegram responses back to SDK Bridge
4. Test hybrid flow
   - SDK Bridge → ClaudeRemote → TelegramService → Telegram
   - Telegram → telegram-relay → SDK Bridge → Claude SDK

**Success Criteria:**
- ClaudeRemote connects to SDK Bridge via WebSocket
- Away detection still works
- Notifications routed correctly
- Responses flow back to SDK

**Files Modified:**
```
ClaudeRemote/
├── Services/
│   ├── WebSocketClient.swift    # NEW: replaces HTTPListener
│   ├── NotificationRouter.swift # Updated for WebSocket events
│   └── TelegramService.swift    # No changes needed
```

---

### Phase 4: Session Management & State Recovery (Week 7-8)
**Goal:** Handle multiple sessions, reconnections, state persistence

**Tasks:**
1. Session registry in SDK Bridge
   - Track active sessions (Map<sessionId, Session>)
   - Store pending permissions/questions
   - Cleanup on session end
2. Persistence layer
   - SQLite or JSON file
   - Save: sessionId, pendingRequests, allowedTools
   - Restore on startup
3. Reconnection handling
   - WebSocket client reconnect → resend pending requests
   - Deduplicate notifications (don't spam on reconnect)
4. "Allow Always" feature
   - User can approve tool permanently for session
   - Store in session state
   - Auto-approve subsequent calls
5. Multiple concurrent sessions
   - Run multiple Claude instances
   - Each gets unique sessionId
   - telegram-relay shows session/project context

**Success Criteria:**
- Multiple Claude sessions run simultaneously
- Reconnection preserves pending state
- "Allow Always" works
- No duplicate notifications on reconnect

**Files Created/Modified:**
```
sdk-bridge/
├── src/
│   ├── session-manager.ts    # NEW: session registry
│   ├── persistence.ts         # NEW: state storage
│   └── sdk-wrapper.ts         # Updated for multi-session
```

---

### Phase 5: Migration Path & Backwards Compatibility (Week 9-10)
**Goal:** Smooth migration for users, optional hook support

**Tasks:**
1. Create migration guide (MIGRATION.md)
   - Step-by-step instructions
   - Config changes needed
   - Rollback procedure
2. Dual-mode support
   - SDK Bridge can optionally receive HTTP POSTs (legacy hooks)
   - Allows gradual migration
3. Environment detection
   - Auto-detect if running under SDK or CLI
   - Fallback behavior for pure CLI users
4. Update README.md
   - Document both modes
   - Explain SDK benefits
   - Prerequisites (Node.js version, etc.)
5. Testing on fresh install
   - Test setup.sh/install script
   - Verify all components start correctly

**Success Criteria:**
- Clear migration documentation
- Both hook and SDK modes work
- Fresh install succeeds
- Rollback is possible

---

### Phase 6: Enhanced Features (Week 11-12)
**Goal:** Leverage SDK capabilities not available in hooks

**New Features:**
1. **Tool output capture**
   - Intercept tool results
   - Show in Telegram (e.g., "Bash command output: ...")
2. **Progress notifications**
   - Long-running tools send intermediate updates
   - "Claude is still working..."
3. **Rich question UI**
   - Multiple choice questions with proper buttons
   - Text input prompts
4. **Session replay**
   - View conversation history from Telegram
   - `/history` command
5. **Cost tracking**
   - Token usage per session
   - Cost estimates

**Success Criteria:**
- At least 3 new features implemented
- Enhanced UX compared to hook version

---

## 4. Technical Decisions

### 4.1 Language Choice for SDK Bridge
**Recommendation:** TypeScript

**Rationale:**
- Matches telegram-relay (easier code sharing)
- Claude Agent SDK has excellent TypeScript support
- Better type safety than Python for WebSocket protocol
- Easy JSON handling

**Alternative:** Python (if team prefers)

### 4.2 WebSocket vs HTTP
**Recommendation:** WebSocket

**Rationale:**
- Bidirectional (responses flow back)
- Real-time (lower latency)
- Stateful (session awareness)
- Standard protocol

**Alternative:** HTTP with polling (worse UX)

### 4.3 State Storage
**Recommendation:** SQLite

**Rationale:**
- Lightweight (no separate DB server)
- ACID guarantees (crash recovery)
- Easy queries (session history)
- Portable (single file)

**Alternative:** JSON files (simpler but less robust)

### 4.4 Swift App Fate
**Recommendation:** Keep it (Option B)

**Rationale:**
- Menu bar presence is valuable UX
- Away detection works well
- macOS notifications when present
- Minimal changes needed

**Alternative:** Remove it (SDK Bridge does everything)

---

## 5. Risk Assessment

### 5.1 High Risk
| Risk | Impact | Mitigation |
|------|--------|-----------|
| SDK stability/bugs | 🔴 High - core functionality | Thorough testing, fallback to hooks |
| Breaking changes in SDK | 🔴 High - requires rework | Pin SDK version, monitor releases |
| WebSocket reliability | 🟡 Medium - reconnection needed | Implement robust reconnect logic |

### 5.2 Medium Risk
| Risk | Impact | Mitigation |
|------|--------|-----------|
| Increased complexity | 🟡 Medium - harder to debug | Good logging, documentation |
| Multi-session bugs | 🟡 Medium - state conflicts | Thorough session isolation testing |
| Migration friction | 🟡 Medium - user confusion | Clear guide, dual-mode support |

### 5.3 Low Risk
| Risk | Impact | Mitigation |
|------|--------|-----------|
| Performance overhead | 🟢 Low - minimal added latency | Profile and optimize |
| Storage growth | 🟢 Low - SQLite manageable | Periodic cleanup of old sessions |

---

## 6. Testing Strategy

### 6.1 Unit Tests
- SDK Bridge session management
- WebSocket protocol encoding/decoding
- State persistence (save/restore)
- Permission gating logic

### 6.2 Integration Tests
- End-to-end: SDK → Telegram → response → SDK
- Reconnection scenarios
- Multiple concurrent sessions
- Error handling (network failures)

### 6.3 Manual Testing Checklist
```
□ Start SDK Bridge
□ Start telegram-relay
□ Start ClaudeRemote app
□ Verify "away" status triggers Telegram
□ Run Claude session, trigger permission prompt
□ Receive Telegram notification with inline buttons
□ Click "Approve" → session continues
□ Click "Deny" → session stops
□ Trigger AskUserQuestion
□ Receive Telegram notification with question
□ Answer from Telegram → SDK receives answer
□ Test "Allow Always" feature
□ Kill telegram-relay, reconnect → pending state restored
□ Run 2 concurrent sessions → both work independently
□ Switch to "present" → macOS notifications instead
```

---

## 7. Rollback Plan

If SDK approach fails:
1. Keep hook-based system in parallel (don't delete)
2. Document known SDK limitations
3. Provide toggle in settings (SDK vs hooks)
4. Maintain both code paths for 2+ releases

**Rollback triggers:**
- SDK stability issues in production
- Critical bugs not fixable within 2 weeks
- User feedback overwhelmingly negative

---

## 8. Success Metrics

### 8.1 Functional Metrics
- ✅ AskUserQuestion notifications work 100%
- ✅ Tool permission approval flow < 5s latency
- ✅ Reconnection preserves state (0 lost notifications)
- ✅ Multi-session support (≥ 3 concurrent sessions)

### 8.2 Non-Functional Metrics
- Migration guide completeness (100% coverage)
- Unit test coverage (≥ 70%)
- Documentation clarity (user feedback)
- Performance (no worse than hook-based)

---

## 9. Timeline Summary

| Phase | Duration | Deliverable |
|-------|----------|-------------|
| 1. POC | 2 weeks | Working SDK + WebSocket |
| 2. Telegram Integration | 2 weeks | End-to-end notification flow |
| 3. ClaudeRemote Integration | 2 weeks | Hybrid architecture |
| 4. Session Management | 2 weeks | Multi-session, persistence |
| 5. Migration Path | 2 weeks | Documentation, dual-mode |
| 6. Enhanced Features | 2 weeks | New SDK-only features |
| **Total** | **12 weeks** | Production-ready SDK system |

**Buffer:** +2 weeks for unexpected issues
**Realistic Timeline:** 14 weeks (3.5 months)

---

## 10. Open Questions

1. **SDK license compatibility?** (check @anthropic-ai/claude-agent-sdk license)
2. **SDK maturity?** (production-ready or beta?)
3. **How to handle SDK breaking changes?** (pin version? auto-update?)
4. **Cloud deployment?** (SDK Bridge on VPS for remote access?)
5. **Multi-user support?** (multiple Telegram users per SDK Bridge?)

---

## 11. References

- **Claude Agent SDK:** https://github.com/anthropics/claude-agent-sdk
- **claude-relay inspiration:** https://github.com/chadbyte/claude-relay
- **WebSocket protocol:** https://developer.mozilla.org/en-US/docs/Web/API/WebSockets_API
- **grammy Telegram bot:** https://grammy.dev/

---

## 12. Next Steps

1. **Review this plan** with team/stakeholders
2. **Validate assumptions** with Anthropic docs/examples
3. **Setup development environment** (SDK playground)
4. **Start Phase 1 POC** (2 weeks sprint)
5. **Document learnings** after each phase

---

**Last Updated:** 2026-02-16
**Author:** Claude Sonnet 4.5
**Status:** Draft - Awaiting Approval
