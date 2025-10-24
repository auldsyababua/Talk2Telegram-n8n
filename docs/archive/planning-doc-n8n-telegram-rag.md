# n8n Telegram RAG Implementation Planning Document

## Feature Overview

**Feature Name**: n8n-Based Telegram Chat History RAG System

**Feature Description**: 
A production-ready system that processes Telegram chat exports (JSON) through n8n workflows, applies sophisticated T2T2 chunking logic to preserve conversation context, generates vector embeddings, and provides a searchable interface via Telegram bot. This replaces the custom Python T2T2 project with maintainable n8n workflows.

**Complexity**: Complex

## Pre-Planning Research Requirements

### Compatibility Research
- **Framework/Library Versions**: 
  - n8n 1.31.0+ required for improved memory handling in Code nodes
  - PostgreSQL 15+ with pgvector 0.6.0 for HNSW index support
  - Node.js 20.x LTS for better memory management
- **Known Issues**: 
  - n8n Code nodes cause memory spikes with >1000 items (community #31499)
  - pgvector HNSW index creation fails on >1M vectors (GitHub #461)
  - OpenAI embedding API: 8191 token limit, 350K-1M TPM rate limits
- **Integration Challenges**: 
  - n8n workflow size limitations with complex Code node logic
  - Concurrent pgvector writes can cause deadlocks
  - Telegram export files can exceed 1GB with media

### Best Practices Investigation
- **Industry Standards**: 
  - Chunk messages by sender within 2-minute windows (from T2T2)
  - Preserve reply chains and cross-references
  - Use HNSW indexes for vector search at scale
- **Performance Benchmarks**: 
  - Target: 50-100 messages/second processing
  - Embedding generation: <100ms per chunk
  - Search latency: <200ms for 95th percentile
- **Security Considerations**: 
  - Never store OpenAI API keys in workflows
  - Implement row-level security in PostgreSQL
  - Sanitize user queries before vector search

## Requirements

### Functional Requirements
1. Process Telegram JSON exports from 39 work chats (10NetZero folder)
2. Apply T2T2 smart chunking: group by sender, 2-min windows, preserve replies
3. Generate embeddings for chunks with metadata preservation
4. Provide Telegram bot interface for natural language search
5. Support incremental updates for new messages

### Non-Functional Requirements
- **Performance**: Process 100K+ messages without OOM, leverage AI Workhorse's 128GB RAM
- **Security**: API keys in n8n credentials only, no plaintext storage
- **Scalability**: Handle 1M+ embeddings with sub-second search
- **Compatibility**: PostgreSQL 14+, n8n 1.25+, Node.js 18+
- **Maintainability**: Modular workflows, clear error handling, progress tracking

### Technical Requirements
- **Language**: JavaScript (n8n Code nodes), Python (pre-processing)
- **Framework**: n8n workflow automation, Supabase (PostgreSQL + pgvector)
- **Dependencies**: 
  - n8n-nodes-langchain (for embeddings)
  - @n8n/n8n-nodes-langchain.vectorstoresupabase
  - Python: ijson, psycopg2-binary, tqdm
- **Infrastructure**: 
  - Supabase (existing instance with pgvector enabled)
  - Railway deployment for bot services
  - n8n Cloud or self-hosted on AI Workhorse
- **External Services**: 
  - OpenAI Embeddings API (cloud-first approach)
  - Telegram Bot API (@talk2telegrambot existing)
  - Railway hosting (https://t2t2-production.up.railway.app)

## Risk Assessment

### Technical Risks
- **Risk 1**: n8n OOM on large JSON | Likelihood: L | Impact: M | Mitigation: Pre-process with Python, 16GB allocation on AI Workhorse
- **Risk 2**: OpenAI rate limits | Likelihood: M | Impact: H | Mitigation: Exponential backoff, local Ollama on RTX 5090
- **Risk 3**: pgvector performance degradation | Likelihood: L | Impact: M | Mitigation: HNSW index, NVMe storage, 32 CPU threads

### Integration Risks
- **Dependency Conflicts**: n8n-nodes-langchain version compatibility
- **API Changes**: OpenAI embedding dimension changes
- **Data Migration**: Existing T2T2 data compatibility

## Implementation Strategy

### Architecture Overview
```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Telegram Export │────▶│ Python Pre-proc │────▶│ n8n Import WF   │
│ (JSON Files)    │     │ (Batch Creator) │     │ (Chunks→Embed)  │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                          │
                                                          ▼
                        ┌─────────────────┐     ┌─────────────────┐
                        │ n8n Sync WF     │────▶│ Supabase Cloud  │
                        │ (New Messages)  │     │ (pgvector)      │
                        └─────────────────┘     └─────────────────┘
                                                          ▲
┌─────────────────┐     ┌─────────────────┐              │
│ Telegram Bot    │◀────│ n8n Search WF   │──────────────┘
│ @talk2telegram  │     │ (RAG Pipeline)  │
│ (Railway)       │     └─────────────────┘
└─────────────────┘
```

**Cloud Services Configuration:**
- **Supabase Instance**: `https://tzsfkbwpgklwvsyypacc.supabase.co`
- **Railway Service**: `https://t2t2-production.up.railway.app`
- **Telegram Bot**: `@talk2telegrambot`

### Integration Points
1. **Internal APIs**: n8n Supabase node, Supabase Vector Store, OpenAI embeddings
2. **External Services**: OpenAI API, Telegram Bot API, Railway webhooks
3. **Data Stores**: Supabase tables (telegram_files with embeddings, user_sessions, processing_state)

### Recommended Tech Stack
| Component | Recommended Version | Justification | Alternatives |
|-----------|-------------------|---------------|--------------|
| n8n | 1.31.0+ | Memory handling improvements, stable pgvector node | 1.25.0 minimum |
| PostgreSQL | 15.4 | Best pgvector performance, JSON improvements | 14.x acceptable |
| pgvector | 0.6.0 | HNSW index support, bug fixes | 0.5.0 minimum |
| Node.js | 20.11.0 LTS | Memory management, performance | 18.x fallback |
| Python | 3.11+ | ijson performance, type hints | 3.9+ acceptable |
| OpenAI API | text-embedding-3-large | 3072 dimensions, best quality | ada-002 fallback |

## Test Categories Required

Minimum test categories:
- [x] Happy Path (process 100 messages successfully)
- [x] Edge Cases (empty messages, huge chunks, special characters)
- [x] Error Handling (API failures, OOM recovery)
- [ ] Property-Based (chunking consistency)
- [x] Integration (pgvector queries, bot responses)
- [x] Performance (memory usage, processing speed)
- [ ] Security (SQL injection, API key exposure)
- [ ] Compatibility (PostgreSQL versions)
- [x] Regression (search quality)

## Acceptance Criteria

1. GIVEN a 100MB Telegram export WHEN processed THEN completes without OOM
2. GIVEN a work conversation WHEN chunked THEN preserves 2-minute context windows
3. GIVEN a search query WHEN executed THEN returns relevant results in <200ms
4. GIVEN an API rate limit WHEN hit THEN gracefully retries with backoff
5. GIVEN a reply chain WHEN indexed THEN maintains parent-child relationships

## Implementation Phases

### Phase 1: Foundation
- [ ] Verify Supabase pgvector extension enabled
- [ ] Configure n8n (Cloud or self-hosted) with Supabase credentials
- [ ] Adapt existing telegram_files table schema for new chunks
- [ ] Set up Python environment with dependencies
- [ ] Initialize Git repository with .gitignore

### Phase 2: Core Implementation
- [ ] Deploy Python pre-processor script
- [ ] Import n8n workflow template 3763
- [ ] Modify workflow for Telegram JSON structure
- [ ] Implement T2T2 chunking logic in Code node
- [ ] Configure OpenAI embeddings node

### Phase 3: Integration
- [ ] Connect pgvector for storage
- [ ] Test with 100-message sample
- [ ] Implement search workflow
- [ ] Configure Telegram bot webhook
- [ ] Add error handling and retries

### Phase 4: Polish & Optimization
- [ ] Create HNSW indexes after bulk load
- [ ] Implement progress tracking
- [ ] Add monitoring views
- [ ] Document API keys setup
- [ ] Performance tuning

## Monitoring & Success Metrics

### Key Performance Indicators
- **Processing Rate**: >200 messages/second (with AI Workhorse specs)
- **Memory Usage**: <16GB during import (128GB available)
- **Search Latency**: p95 <100ms (NVMe + 32 threads)
- **Embedding Cost**: <$0.10 per 1000 messages (or $0 with local Ollama)
- **Error Rate**: <0.1% message loss

### Rollback Strategy
- **Trigger Conditions**: Memory usage >3.5GB, error rate >5%, search timeout
- **Rollback Procedure**: 
  1. Stop n8n workflow execution
  2. Restore PostgreSQL from pre-import backup
  3. Revert to previous n8n workflow version
  4. Switch to Python direct implementation
- **Data Recovery**: PostgreSQL PITR backup every 4 hours

## Example Usage

```javascript
// n8n Code node chunking example
const chunk = {
  chunk_text: "John: Hey, did you see the report? Mary: Yes, reviewing now.",
  metadata: {
    chat_name: "Work Team",
    timestamp: "2024-01-15T10:30:00Z",
    is_grouped: true,
    message_count: 2,
    likely_response_to: { msg_id: 123, text: "Report ready?" }
  }
};

// Search query
const results = await searchMessages("report review", 10);
```

## Out of Scope

What this feature should NOT do:
- Process media files (images, videos)
- Real-time message streaming
- End-to-end encryption handling
- Multi-language translation
- Sentiment analysis

## Anti-Patterns to Avoid

- No loading entire JSON files into n8n memory
- No synchronous OpenAI API calls without retry
- No creating indexes before bulk insert
- No hardcoded chat IDs or API keys
- No processing all chats simultaneously

## Lessons from T2T2

### What Went Wrong

The T2T2 project, while sophisticated in its chunking and embedding logic, faced critical operational challenges:

1. **Authentication Complexity**
   - Telegram's MTProto authentication required phone numbers, session management, and 2FA handling
   - Session strings would expire, requiring re-authentication
   - Multiple authentication methods (QR, phone, session files) all had reliability issues
   - Users often couldn't complete the auth flow, blocking access to the entire system

2. **Real-time Sync Overhead**
   - Maintaining persistent Telethon connections for 39+ chats was resource-intensive
   - Webhook/polling mechanisms would miss messages during downtime
   - Rate limits on Telegram API made catching up expensive

3. **Operational Brittleness**
   - Single point of failure: if auth broke, entire system was unusable
   - No fallback for when Telegram API was down
   - Complex session management across multiple user accounts

### Key Insight: Manual Export First

By requiring manual export as the primary data source:
- **Eliminates authentication complexity entirely**
- Users already know how to export from Telegram Desktop
- One-time effort yields complete historical data
- System only needs to handle incremental updates (much simpler)

### Architectural Simplification

T2T2 Approach:
```
User → Auth → Session Management → API Polling → Processing
         ↑ (fails often)
```

New Approach:
```
User → Manual Export → Process Once → Incremental Updates Only
         ↑ (always works)
```

This pivot from "live connection required" to "batch process with updates" dramatically improves reliability and user experience.

## Required Credentials

### Existing Services (from T2T2)
- **Telegram Bot**: @talk2telegrambot
- **Telegram API ID**: (stored in Railway env vars)
- **Telegram API Hash**: (stored in Railway env vars)
- **Telegram Bot Token**: (stored in Railway env vars)
- **Supabase URL**: https://tzsfkbwpgklwvsyypacc.supabase.co
- **Supabase Service Key**: (stored in Railway env vars)
- **OpenAI API Key**: (for embeddings)

### n8n Configuration
All credentials should be configured in n8n's credential store, not in workflows.

## Environment Variables

### Production Environment (Railway)
All production environment variables are configured in the Railway dashboard:
- Navigate to your Railway project dashboard
- Click on the service (e.g., "t2t2-production")
- Go to the "Variables" tab
- Add/edit environment variables as key-value pairs
- Changes are automatically deployed

**Production Variables Location**: Railway Dashboard → Service → Variables

### Local Development (.env files)
For local development and testing:

**n8n Environment Variables**:
- Located in n8n's credential store (UI-based configuration)
- Access via: n8n Editor → Credentials → Create/Edit credentials
- Stored encrypted in n8n's database

**Python Pre-processor Variables**:
- Create `.env` file in project root: `/Users/colinaulds/Desktop/projects/n8n-telegram-rag/.env`
- Copy from example: `cp .env.example .env`
- Edit with actual values from 1Password

**Supabase Connection**:
```env
SUPABASE_URL=https://tzsfkbwpgklwvsyypacc.supabase.co
SUPABASE_SERVICE_KEY=eyJ...  # From Railway or 1Password
DATABASE_URL=postgresql://...  # Direct connection string
```

**OpenAI API**:
```env
OPENAI_API_KEY=sk-...  # From 1Password
```

**Telegram Bot** (if needed for direct bot operations):
```env
TELEGRAM_BOT_TOKEN=123456789:ABC...  # From Railway vars
TELEGRAM_API_ID=12345678
TELEGRAM_API_HASH=abcdef1234567890
```

### Variable Management Workflow

1. **Store in 1Password**: All API keys originate in 1Password
2. **Retrieve with `key` command**: `key openai` copies to clipboard
3. **Configure in appropriate location**:
   - Railway Dashboard for production
   - n8n Credentials UI for workflows
   - `.env` files for local Python scripts
4. **Never commit secrets**: Ensure `.env` is in `.gitignore`

### n8n Workflow Access
Within n8n workflows, access credentials via:
- OpenAI Credentials node (configure once, reuse everywhere)
- Supabase Credentials node
- HTTP Request node with credential type

**Important**: Never use `{{ $env.VARIABLE }}` in n8n for secrets. Always use the credential system.

## Open Questions

1. **Should we implement local embeddings (Ollama) from day one?**
   - **Answer**: No. Use OpenAI cloud embeddings for team accessibility. Non-tech founders need simplicity. Ollama requires GPU setup and maintenance.

2. **How to handle edited/deleted messages in exports?**
   - **Answer**: Keep all messages as-is in the database. If others delete messages, preserve them. If messages are edited, ignore edits for now - keep original version only.

3. **Preferred backup strategy for 1M+ vectors?**
   - **Answer**: Rely on Supabase's built-in backups. They handle point-in-time recovery and automated backups in the cloud.

---

**Critical Path Actions**:

1. **Pre-process exports** with Python script to avoid n8n memory issues
2. **Batch size = 5** in Split In Batches node (proven limit)
3. **Create indexes AFTER** bulk insert (10x faster)
4. **Monitor memory** with `docker stats` during import
5. **Test with 100 messages** before full dataset