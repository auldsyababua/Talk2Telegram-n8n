# Architecture Decision Record: Building on Existing Work

**Date**: 2025-10-24
**Status**: Proposed
**Decision**: Build from scratch with selective code reuse from existing projects

## Context

Research revealed several existing Telegram and Slack RAG implementations:

### Existing Projects Analyzed

1. **groupultra/telegram-search**
   - PostgreSQL + pgvector + Vue 3 frontend
   - Semantic search on Telegram messages
   - Per-message indexing (no conversation-aware chunking)
   - Event-driven architecture
   - Repository: https://github.com/groupultra/telegram-search

2. **DmitriiK/telegram_rag_search**
   - Topic tree building from message reply chains
   - LLM-powered topic summarization
   - Elasticsearch for vector search
   - Russian→English translation focus
   - Repository: https://github.com/DmitriiK/telegram_rag_search

3. **vectara/ragtime**
   - Open source bot for Slack AND Discord
   - Excellent thread/conversation management
   - SQLite for conversation ID mapping
   - **Proprietary Vectara RAG platform** (deal breaker)
   - Repository: https://github.com/vectara/ragtime

4. **Slack RAG "5-6% improvement" article**
   - Described hybrid chunking approach (thread → time → semantic)
   - **No public code available**
   - Blog post only: https://dev.to/criscmd/how-i-boosted-slack-rag-accuracy-by-5-6-with-smarter-chunking-1kf9

## Decision

**Build from scratch, but incorporate proven patterns from existing projects.**

### Rationale

#### Why not fork/adapt existing projects?

**groupultra/telegram-search:**
- ❌ No conversation-aware chunking (our core innovation)
- ❌ Per-message indexing loses context
- ❌ Would require significant refactoring of core architecture
- ✅ Good reference for PostgreSQL + pgvector integration

**DmitriiK/telegram_rag_search:**
- ✅ Excellent thread tree building algorithm
- ❌ Elasticsearch instead of PostgreSQL
- ❌ Focused on Russian translation, not general-purpose
- ❌ Missing time-window clustering and semantic splitting

**vectara/ragtime:**
- ✅ Excellent multi-platform architecture
- ✅ Great conversation mapping pattern
- ❌ **Locked into proprietary Vectara platform**
- ❌ Can't customize chunking strategy
- ❌ Monthly API costs vs. our open-source approach

#### Why build from scratch?

1. **Core Innovation**: None of the existing projects implement our 4-level hybrid chunking strategy
2. **Tech Stack Control**: We want PostgreSQL + pgvector, not Elasticsearch or Vectara
3. **Open Source**: Full control without proprietary dependencies
4. **Multi-Platform Design**: Can design for extensibility from day one
5. **Learning**: Existing projects show it's feasible, but we can do better

## What We'll Borrow

### 1. From vectara/ragtime: Conversation Mapping Pattern

```python
# SQLite-based conversation to chunk mapping
class ConversationMapper:
    """
    Maps platform-specific conversation IDs to internal chunk IDs
    Inspired by vectara/ragtime approach
    """
    def __init__(self, db_path='conversation_map.db'):
        self.conn = sqlite3.connect(db_path)
        self._create_tables()

    def _create_tables(self):
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS conversation_map (
                platform TEXT,
                platform_thread_id TEXT,
                internal_chunk_id TEXT,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (platform, platform_thread_id, internal_chunk_id)
            )
        """)

    def map_thread_to_chunks(self, platform, thread_id, chunk_ids):
        """Store relationship between platform thread and our chunks"""
        for chunk_id in chunk_ids:
            self.conn.execute(
                "INSERT OR IGNORE INTO conversation_map VALUES (?, ?, ?, ?)",
                (platform, thread_id, chunk_id, datetime.now())
            )
        self.conn.commit()

    def get_chunks_for_thread(self, platform, thread_id):
        """Retrieve all chunks belonging to a conversation thread"""
        cursor = self.conn.execute(
            "SELECT internal_chunk_id FROM conversation_map WHERE platform=? AND platform_thread_id=?",
            (platform, thread_id)
        )
        return [row[0] for row in cursor.fetchall()]
```

**Why:** This pattern enables context-aware queries like "show me everything from that discussion about the deadline"

### 2. From DmitriiK/telegram_rag_search: Enhanced Thread Detection

```python
def build_discussion_tree(messages):
    """
    Build topic tree from explicit parent-child reply links
    Inspired by DmitriiK's approach to handle "parent child relations"
    """
    # Group messages by root thread
    threads = {}
    message_map = {msg.id: msg for msg in messages}

    for msg in messages:
        # Find ultimate root of reply chain
        root = msg
        chain = []

        while root.reply_to_message_id and root.reply_to_message_id in message_map:
            root = message_map[root.reply_to_message_id]
            chain.append(root)

            # Prevent infinite loops
            if len(chain) > 100:
                break

        root_id = root.id
        if root_id not in threads:
            threads[root_id] = {
                'root': root,
                'messages': [],
                'depth': 0
            }

        threads[root_id]['messages'].append(msg)
        threads[root_id]['depth'] = max(threads[root_id]['depth'], len(chain))

    return threads
```

**Why:** DmitriiK correctly identified that "standard search does not work well as it is not considering parent child relations." This solves that.

### 3. From groupultra/telegram-search: Event-Driven Processing

```python
from eventemitter import EventEmitter

class MessagePipeline:
    """
    Event-driven processing pipeline
    Inspired by groupultra/telegram-search's clean architecture
    """
    def __init__(self):
        self.event_bus = EventEmitter()

        # Register event handlers
        self.event_bus.on('messages_parsed', self.on_messages_parsed)
        self.event_bus.on('chunks_created', self.on_chunks_created)
        self.event_bus.on('embeddings_generated', self.on_embeddings_generated)
        self.event_bus.on('chunks_stored', self.on_chunks_stored)

    def process_export(self, export_file):
        """Trigger processing pipeline"""
        messages = parse_export(export_file)
        self.event_bus.emit('messages_parsed', messages)

    def on_messages_parsed(self, messages):
        chunks = self.chunker.chunk(messages)
        self.event_bus.emit('chunks_created', chunks)

    def on_chunks_created(self, chunks):
        embeddings = self.embedder.embed_batch([c.text for c in chunks])
        self.event_bus.emit('embeddings_generated', chunks, embeddings)

    def on_embeddings_generated(self, chunks, embeddings):
        self.db.insert_chunks(chunks, embeddings)
        self.event_bus.emit('chunks_stored', len(chunks))

    def on_chunks_stored(self, count):
        print(f"Successfully stored {count} chunks")
```

**Why:** Clean separation of concerns, easy to add monitoring/logging, testable components

## What We Won't Borrow

### From vectara/ragtime
- ❌ Vectara API dependency (proprietary, costs money)
- ❌ Their chunking strategy (we have a better one)

### From groupultra/telegram-search
- ❌ Per-message indexing (loses conversation context)
- ❌ Vue 3 frontend (nice-to-have, but not MVP priority)

### From DmitriiK/telegram_rag_search
- ❌ Elasticsearch (we prefer PostgreSQL)
- ❌ Russian-specific translation pipeline

## Implementation Strategy

### Phase 1: Core Chunking Engine (Week 1-2)
**Build from scratch:**
- Thread chunker (inspired by DmitriiK's tree building)
- Time-window clusterer (our innovation)
- Semantic splitter (our innovation)
- Token splitter with overlap (our innovation)
- Hybrid orchestrator (our innovation)

**Borrow patterns:**
- Event-driven architecture (groupultra)
- Conversation mapping (vectara)

### Phase 2: Database & Storage (Week 2-3)
**Build from scratch:**
- PostgreSQL + pgvector schema
- Chunk storage with metadata
- Vector similarity search

**Borrow patterns:**
- Connection pooling (groupultra)
- Index creation strategy (research from existing projects)

### Phase 3: Telegram Integration (Week 3-4)
**Build from scratch:**
- Telegram export parser (we already have src/preprocessing/telegram_parser.py)
- Telegram adapter for unified message schema

**Borrow patterns:**
- Message filtering and preprocessing (groupultra)

### Phase 4: Multi-Platform Foundation (Week 5-6)
**Build from scratch:**
- Unified message schema
- Platform adapter interface
- Conversation mapper (inspired by vectara)

## Expected Outcomes

### Advantages of Our Approach
1. **Novel Chunking**: 4-level hybrid strategy not implemented elsewhere
2. **Open Source**: No proprietary dependencies (vs. Vectara)
3. **Cost-effective**: PostgreSQL + pgvector vs. Elasticsearch or Vectara
4. **Multi-platform**: Designed for extensibility from day one
5. **Best of Breed**: Incorporates proven patterns from multiple projects

### Unique Value Proposition
Our system will be the first to implement:
- ✅ Thread-based chunking + time-window clustering + semantic boundaries + token overlap
- ✅ Open source Telegram RAG with sophisticated conversation-aware chunking
- ✅ PostgreSQL + pgvector for cost-effective self-hosting
- ✅ Multi-platform ready (Telegram → WhatsApp → Slack → Discord)

## Alternatives Considered

### Alternative 1: Fork groupultra/telegram-search
**Pros:** Head start on Telegram integration and UI
**Cons:** Would spend more time refactoring than building from scratch
**Decision:** Rejected - core chunking needs complete rewrite anyway

### Alternative 2: Adapt vectara/ragtime
**Pros:** Excellent architecture, multi-platform support
**Cons:** Locked into proprietary Vectara platform, can't customize chunking
**Decision:** Rejected - defeats purpose of open source RAG system

### Alternative 3: License Vectara + Build Custom Chunking on Top
**Pros:** Leverage their infrastructure
**Cons:** Monthly costs, less control, can't fully customize chunking
**Decision:** Rejected - not cost-effective for users

## References

- groupultra/telegram-search: https://github.com/groupultra/telegram-search
- DmitriiK/telegram_rag_search: https://github.com/DmitriiK/telegram_rag_search
- vectara/ragtime: https://github.com/vectara/ragtime
- Slack RAG chunking article: https://dev.to/criscmd/how-i-boosted-slack-rag-accuracy-by-5-6-with-smarter-chunking-1kf9

## Status

**Decision**: Build from scratch with selective pattern reuse
**Approved**: 2025-10-24
**Next Steps**:
1. Implement conversation mapper (inspired by vectara)
2. Enhance thread detector with discussion trees (inspired by DmitriiK)
3. Proceed with hybrid chunking implementation (original work)

---

*This decision may be revisited if significant new open-source projects emerge with superior chunking implementations.*
