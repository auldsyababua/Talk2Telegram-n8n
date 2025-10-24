# Talk2Telegram RAG System Architecture

## Project Vision

A multi-platform RAG (Retrieval-Augmented Generation) system that allows users to query their entire chat history across messaging platforms (starting with Telegram). The system uses advanced chunking strategies specifically designed for conversational data to enable queries like:

- "What did John say about the delivery last Friday?"
- "Create a timeline of events regarding the Y lawsuit based on chat history"
- "Show me all action items from the engineering team chat this month"

## Core Architecture Principles

### 1. Batch Processing Over Live Connections
**Philosophy**: Instead of maintaining complex real-time connections, use manual exports + incremental updates

**Benefits**:
- No authentication complexity (MTProto, 2FA, session management)
- No single point of failure
- Better reliability and user experience
- Easier to extend to other platforms

### 2. Smart Chunking for Conversational Context
**Philosophy**: Conversations are not documents - they need conversation-aware chunking

**Key Challenges**:
- Messages are short and informal
- Context spans multiple messages
- Reply chains and threads create non-linear conversation flow
- Time-based clustering (conversation bursts)
- Cross-references and mentions

### 3. Extensible Multi-Platform Design
**Philosophy**: Start with Telegram, but design for multiple messaging platforms from day one

## System Components

### Phase 1: Telegram (Current Focus)

```
┌─────────────────────────────────────────────────────────────────┐
│                        USER INTERACTION                          │
│  Telegram Export → Manual JSON Download → Upload to System      │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                     PREPROCESSING LAYER                          │
│  • Python streaming parser (ijson)                               │
│  • Memory-efficient batch creation                               │
│  • Extract chat metadata                                         │
│  • Output: Manageable JSON batches                               │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                     CHUNKING ENGINE (Core)                       │
│  • Hybrid conversation-aware chunking                            │
│  • Thread preservation                                           │
│  • Time-window clustering                                        │
│  • Reply chain tracking                                          │
│  • Semantic boundary detection                                   │
│  • Context overlap for continuity                                │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                     EMBEDDING LAYER                              │
│  • OpenAI text-embedding-3-large (3072 dims)                     │
│  • Batch processing with rate limiting                           │
│  • Fallback: Local Ollama on RTX 5090                            │
│  • Metadata enrichment                                           │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                     STORAGE LAYER                                │
│  • PostgreSQL 15+ with pgvector extension                        │
│  • HNSW indexes for fast similarity search                       │
│  • Metadata JSONB for flexible querying                          │
│  • Deferred index creation (post bulk-load)                      │
└────────────────────┬────────────────────────────────────────────┘
                     │
                     ▼
┌─────────────────────────────────────────────────────────────────┐
│                     RETRIEVAL & QUERY LAYER                      │
│  • Vector similarity search                                      │
│  • Hybrid search (vector + metadata filters)                     │
│  • Context reconstruction (linked chunks)                        │
│  • Timeline generation                                           │
│  • Telegram bot interface (@talk2telegrambot)                    │
└─────────────────────────────────────────────────────────────────┘
```

### Phase 2: Multi-Platform Extension (Future)

```
┌─────────────────────────────────────────────────────────────────┐
│                    PLATFORM ADAPTERS                             │
│  ┌─────────────┬──────────────┬──────────────┬───────────────┐  │
│  │  Telegram   │   WhatsApp   │    Slack     │   Discord     │  │
│  │   Adapter   │    Adapter   │   Adapter    │   Adapter     │  │
│  └─────────────┴──────────────┴──────────────┴───────────────┘  │
│         ↓              ↓              ↓              ↓           │
│  ┌──────────────────────────────────────────────────────────┐   │
│  │          Unified Message Schema                          │   │
│  └──────────────────────────────────────────────────────────┘   │
└─────────────────────────────────────────────────────────────────┘
                            ↓
                   (Flows into Chunking Engine)
```

## Unified Message Schema (For Multi-Platform)

Every message adapter normalizes to this schema:

```json
{
  "message_id": "unique_id",
  "platform": "telegram|whatsapp|slack|discord",
  "chat_id": "chat_identifier",
  "chat_name": "human_readable_name",
  "chat_type": "private|group|channel",
  "sender_id": "user_identifier",
  "sender_name": "human_readable_name",
  "timestamp": "ISO8601_datetime",
  "text": "message_content",
  "reply_to": {
    "message_id": "parent_message_id",
    "text_preview": "first_100_chars"
  },
  "thread_id": "thread_identifier",
  "mentions": ["user_id_1", "user_id_2"],
  "attachments": [
    {
      "type": "image|video|file|link",
      "url": "attachment_url",
      "description": "optional_description"
    }
  ],
  "reactions": [
    {
      "emoji": "👍",
      "users": ["user_id_1", "user_id_2"]
    }
  ],
  "metadata": {
    "edited": true,
    "forwarded_from": "optional_source",
    "platform_specific": {}
  }
}
```

## Data Flow: From Export to Query

### 1. Initial Full Export
```
User exports chat → Upload → Preprocess → Chunk → Embed → Store
                     (Python)  (n8n)     (OpenAI)  (pgvector)
```

### 2. Incremental Updates (Future)
```
Platform API → Fetch new messages → Chunk → Embed → Store
               (Last message ID)
```

### 3. Query Flow
```
User question → Embed query → Vector search → Retrieve chunks
                (OpenAI)      (pgvector)      + metadata
                ↓
Context reconstruction → LLM generation → Response
(Link related chunks)    (Claude/GPT)
```

## Storage Strategy

### PostgreSQL Schema Design

**Core Tables**:
1. `platforms` - Registry of connected messaging platforms
2. `chats` - Chat/group/channel metadata
3. `raw_messages` - Original messages (normalized schema)
4. `message_chunks` - Chunked conversation segments
5. `chunk_embeddings` - Vector embeddings + metadata
6. `chunk_relationships` - Links between related chunks
7. `processing_state` - Import progress tracking
8. `search_history` - Query analytics

**Key Design Decisions**:
- **Denormalization**: Store essential metadata in chunk_embeddings for fast retrieval
- **JSONB**: Flexible metadata storage with GIN indexes
- **HNSW**: Fast approximate nearest neighbor search
- **Deferred Indexing**: Create indexes AFTER bulk load (10x faster)

## Technology Stack

### Core Components
| Component | Technology | Version | Purpose |
|-----------|-----------|---------|---------|
| Orchestration | n8n | 1.31.0+ | Workflow automation |
| Database | PostgreSQL | 15.4+ | Primary data store |
| Vector Search | pgvector | 0.6.0+ | Similarity search |
| Embeddings | OpenAI API | text-embedding-3-large | Vector generation |
| Preprocessing | Python | 3.11+ | Stream large JSON files |
| Bot Interface | Telegram Bot API | Latest | User interface |

### Optional Components
| Component | Technology | Purpose |
|-----------|-----------|---------|
| Local Embeddings | Ollama + nomic-embed-text | Offline fallback |
| Monitoring | n8n workflows + PostgreSQL views | Progress tracking |
| Deployment | Railway / Self-hosted | Production hosting |

## Project Structure

```
Talk2Telegram-n8n/
├── ARCHITECTURE.md           # This file - system design
├── CHUNKING_STRATEGY.md      # Detailed chunking algorithm
├── IMPLEMENTATION_ROADMAP.md # Step-by-step build plan
├── README.md                 # Quick start guide
│
├── docs/                     # Documentation
│   ├── api/                  # API documentation
│   ├── research/             # Research notes
│   │   ├── slack-rag-findings.md
│   │   ├── semantic-chunking.md
│   │   └── vector-db-strategies.md
│   ├── tutorials/            # User guides
│   └── decisions/            # Architecture decision records
│       └── 001-batch-vs-streaming.md
│
├── database/                 # Database artifacts
│   ├── schema/
│   │   ├── 001_initial_schema.sql
│   │   ├── 002_add_platforms.sql
│   │   └── 003_chunk_relationships.sql
│   ├── migrations/           # Migration scripts
│   ├── seeds/                # Sample data
│   └── views/                # Useful views & functions
│
├── n8n-workflows/            # n8n workflow definitions
│   ├── 01_telegram_import.json
│   ├── 02_incremental_sync.json
│   ├── 03_query_interface.json
│   └── README.md
│
├── src/                      # Source code
│   ├── preprocessing/        # Data preprocessing
│   │   ├── telegram_parser.py
│   │   ├── whatsapp_parser.py  # Future
│   │   └── base_parser.py      # Shared interface
│   ├── chunking/             # Chunking engine
│   │   ├── hybrid_chunker.py
│   │   ├── thread_detector.py
│   │   ├── semantic_splitter.py
│   │   └── context_overlap.py
│   ├── embedding/            # Embedding utilities
│   │   ├── openai_embedder.py
│   │   └── ollama_embedder.py
│   ├── adapters/             # Platform adapters
│   │   ├── telegram_adapter.py
│   │   └── base_adapter.py
│   └── utils/                # Shared utilities
│       ├── config.py
│       ├── logger.py
│       └── rate_limiter.py
│
├── tests/                    # Test suite
│   ├── unit/
│   ├── integration/
│   └── fixtures/
│
├── scripts/                  # Utility scripts
│   ├── export_telegram.sh
│   ├── create_indexes.sql
│   └── benchmark.py
│
├── config/                   # Configuration
│   ├── config.example.yaml
│   └── platforms.yaml
│
└── .github/                  # GitHub specific
    └── workflows/
        └── ci.yml
```

## Key Architectural Decisions

### Decision 1: Batch Processing Over Streaming
**Context**: Original T2T2 used MTProto for real-time sync
**Decision**: Use manual JSON exports + incremental updates
**Rationale**:
- Eliminates authentication complexity
- No session management
- More reliable
- Better user experience
- Easier to extend to platforms without live APIs (WhatsApp)

**Trade-offs**: Not real-time (acceptable for use case)

### Decision 2: Hybrid Chunking Strategy
**Context**: Standard fixed-size chunking loses conversation context
**Decision**: Multi-level chunking (thread → time-window → semantic → token-limit)
**Rationale**:
- Slack RAG showed 5-6% accuracy improvement
- Preserves conversation coherence
- Handles non-linear reply chains
- Maintains temporal relationships

**Trade-offs**: More complex implementation (worth it for accuracy)

### Decision 3: PostgreSQL + pgvector Over Specialized Vector DB
**Context**: Could use Pinecone, Weaviate, Qdrant, etc.
**Decision**: PostgreSQL with pgvector extension
**Rationale**:
- Single database for all data (simpler architecture)
- JSONB for flexible metadata
- Mature tooling and ecosystem
- Supabase already configured
- HNSW performance is excellent

**Trade-offs**: Slightly slower than specialized DBs at massive scale (not a concern for initial version)

### Decision 4: n8n for Orchestration
**Context**: Could use Python scripts, Airflow, custom backend
**Decision**: n8n workflow automation
**Rationale**:
- Visual workflow design
- Built-in error handling and retries
- Easy monitoring
- No-code for future users
- Good PostgreSQL integration

**Trade-offs**: Some memory limitations (mitigated with preprocessing)

## Performance Targets

### Processing
- **Throughput**: 50-100 messages/second end-to-end
- **Initial Import**: 100K messages in ~30 minutes
- **Memory**: <3GB during import
- **Chunking**: 500 chunks/second

### Search
- **Latency**: <200ms for 95th percentile
- **Relevance**: >85% user satisfaction on test queries
- **Concurrent Users**: 10+ simultaneous queries

### Storage
- **Compression**: ~5KB per message (including embeddings)
- **Index Size**: ~30% of vector data size
- **Scalability**: 1M+ messages per chat without degradation

## Security & Privacy

### Data Protection
- All data stored locally or in user's Supabase instance
- No message content sent to third parties (except embedding API)
- OpenAI API: zero retention policy for embeddings
- Option for local embeddings (Ollama) for sensitive data

### Access Control
- User owns their data
- Telegram bot authentication via user_id verification
- No multi-tenant access by design

### Compliance
- GDPR: User can export/delete all data
- Data minimization: Only store what's needed for search
- Audit logs: search_history table tracks all queries

## Extensibility Points

### Adding New Platforms
1. Create adapter in `src/adapters/` implementing `BaseAdapter`
2. Map platform schema to unified message schema
3. Add platform entry to `platforms` table
4. Create export parser in `src/preprocessing/`
5. Test with sample data

### Custom Chunking Strategies
1. Implement in `src/chunking/` implementing `BaseChunker`
2. Register in config
3. A/B test against default strategy
4. Measure retrieval accuracy improvement

### Alternative Embedding Models
1. Implement embedder in `src/embedding/` implementing `BaseEmbedder`
2. Update vector dimensions in schema
3. Rebuild embeddings for existing data
4. Compare retrieval quality

## Monitoring & Observability

### Key Metrics
- **Import Progress**: processing_state table + n8n execution logs
- **Search Quality**: search_history table with feedback scores
- **Performance**: Query latency, embedding API response times
- **Errors**: Failed chunks, API rate limits, memory issues

### Health Checks
- Database connection and pgvector extension
- Embedding API availability
- n8n workflow execution status
- Telegram bot uptime

## Future Enhancements

### Phase 2 (Multi-Platform)
- WhatsApp export support
- Slack workspace integration
- Discord server export
- Signal backup imports
- Platform selection UI (checkboxes)

### Phase 3 (Advanced Features)
- Multi-modal support (images, voice notes)
- Timeline visualization UI
- Advanced filters (date ranges, participants, sentiment)
- Conversation summaries
- Key points extraction

### Phase 4 (AI Enhancements)
- Automatic tag generation
- Entity extraction (people, places, events)
- Sentiment analysis
- Topic modeling
- Conversation importance scoring

## Success Metrics

### Technical Metrics
- ✅ Process 100K+ messages without failure
- ✅ Search latency <200ms
- ✅ Chunking preserves conversation context (measured by retrieval accuracy)
- ✅ Zero data loss during import

### User Metrics
- ✅ Users can find specific messages with natural language queries
- ✅ Timeline generation is accurate and comprehensive
- ✅ System "just works" without technical knowledge
- ✅ 85%+ user satisfaction with search results

## Questions to Resolve

1. **Chunk size limits**: What's the optimal maximum chunk size? (Need A/B testing)
2. **Overlap percentage**: 10%, 15%, or 20% overlap between chunks?
3. **Thread depth limits**: How deep should we preserve reply chains?
4. **Incremental sync frequency**: Every hour? Daily? User-triggered?
5. **Media handling**: Extract text from images via OCR? Transcribe voice notes?

## References

- Original T2T2 project learnings: `planning-doc-n8n-telegram-rag.md`
- Slack RAG chunking research: [DEV Community article](https://dev.to/criscmd/how-i-boosted-slack-rag-accuracy-by-5-6-with-smarter-chunking-1kf9)
- pgvector documentation: [GitHub](https://github.com/pgvector/pgvector)
- OpenAI embeddings guide: [OpenAI Docs](https://platform.openai.com/docs/guides/embeddings)
