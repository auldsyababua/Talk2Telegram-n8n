# Implementation Roadmap

## Overview

This roadmap breaks down the Talk2Telegram RAG project into achievable milestones with clear deliverables and success criteria.

**Timeline**: 6 weeks (MVP) + 4 weeks (Multi-platform)
**Team Size**: 1-2 developers
**Effort**: ~80-120 hours total

## Project Phases

```
Week 1-2: Foundation & Database
Week 3-4: Chunking Engine
Week 5: Integration & Testing
Week 6: Polish & Deployment
Week 7-10: Multi-Platform Extension (Optional)
```

---

## Phase 1: Foundation & Database Setup (Week 1)

### Objective
Set up infrastructure and validate technical stack

### Tasks

#### 1.1 Repository & Project Structure Setup (2 hours)

**Tasks**:
- [x] Create comprehensive architecture documentation
- [x] Design chunking strategy
- [ ] Reorganize repository structure per `ARCHITECTURE.md`
- [ ] Set up Python virtual environment
- [ ] Create configuration management system

**Commands**:
```bash
# Create directory structure
mkdir -p src/{preprocessing,chunking,embedding,adapters,utils}
mkdir -p tests/{unit,integration,fixtures}
mkdir -p database/{schema,migrations,views,seeds}
mkdir -p n8n-workflows
mkdir -p docs/{api,research,tutorials,decisions}
mkdir -p config scripts

# Python environment
python3.11 -m venv venv
source venv/bin/activate
pip install -r requirements.txt
```

**Deliverables**:
- Clean directory structure
- requirements.txt with dependencies
- config/config.example.yaml

**Success Criteria**:
- ✅ All directories created and organized
- ✅ Python environment activates successfully
- ✅ No legacy files in root directory

#### 1.2 Database Schema Implementation (3 hours)

**Tasks**:
- [ ] Review and update schema.sql with multi-platform support
- [ ] Add platforms table
- [ ] Add chunk_relationships table
- [ ] Create migration scripts
- [ ] Set up Supabase connection

**Schema Updates**:
```sql
-- New table: platforms
CREATE TABLE platforms (
    platform_id SERIAL PRIMARY KEY,
    platform_name VARCHAR(50) UNIQUE NOT NULL, -- telegram, whatsapp, slack
    enabled BOOLEAN DEFAULT true,
    config JSONB,
    created_at TIMESTAMP DEFAULT now()
);

-- New table: chats (normalized)
CREATE TABLE chats (
    chat_id VARCHAR(255) PRIMARY KEY,
    platform_id INTEGER REFERENCES platforms(platform_id),
    chat_name VARCHAR(255),
    chat_type VARCHAR(50), -- private, group, channel
    participant_count INTEGER,
    metadata JSONB,
    created_at TIMESTAMP DEFAULT now()
);

-- Updated: message_embeddings with relationships
ALTER TABLE message_embeddings ADD COLUMN IF NOT EXISTS
    relationships JSONB; -- Stores chunk links

-- New table: chunk_relationships
CREATE TABLE chunk_relationships (
    id SERIAL PRIMARY KEY,
    chunk_id VARCHAR(255) REFERENCES message_embeddings(chunk_id),
    related_chunk_id VARCHAR(255) REFERENCES message_embeddings(chunk_id),
    relationship_type VARCHAR(50), -- split_sibling, temporal_next, cross_reference
    metadata JSONB
);
```

**Commands**:
```bash
# Test database connection
psql $DATABASE_URL -c "SELECT version();"

# Run schema
psql $DATABASE_URL -f database/schema/001_initial_schema.sql
psql $DATABASE_URL -f database/schema/002_add_platforms.sql

# Verify pgvector
psql $DATABASE_URL -c "CREATE EXTENSION IF NOT EXISTS vector;"
psql $DATABASE_URL -c "SELECT * FROM pg_extension WHERE extname = 'vector';"
```

**Deliverables**:
- database/schema/002_add_platforms.sql
- database/schema/003_chunk_relationships.sql
- Database connection test passing

**Success Criteria**:
- ✅ All tables created successfully
- ✅ pgvector extension installed
- ✅ Can query database from Python

#### 1.3 Configuration System (2 hours)

**Tasks**:
- [ ] Create config.yaml structure
- [ ] Implement config loader
- [ ] Set up environment variable management
- [ ] Create secrets management approach

**File**: `src/utils/config.py`
```python
import yaml
import os
from pathlib import Path

class Config:
    def __init__(self, config_path='config/config.yaml'):
        with open(config_path) as f:
            self.config = yaml.safe_load(f)

        # Override with environment variables
        self.database_url = os.getenv('DATABASE_URL', self.config['database']['url'])
        self.openai_api_key = os.getenv('OPENAI_API_KEY')

    def get_chunking_config(self):
        return self.config['chunking']

    def get_embedding_config(self):
        return self.config['embedding']
```

**File**: `config/config.yaml`
```yaml
database:
  url: ${DATABASE_URL}  # From environment
  pool_size: 10

embedding:
  provider: openai  # openai | ollama
  model: text-embedding-3-large
  dimensions: 3072
  batch_size: 100

chunking:
  strategy: hybrid
  thread_chunking:
    enabled: true
    max_thread_depth: 10
    max_thread_tokens: 2000
  time_clustering:
    enabled: true
    window_minutes: 2
  semantic_boundaries:
    enabled: true
    similarity_threshold: 0.7
  token_splitting:
    max_tokens: 500
    overlap_tokens: 75

preprocessing:
  batch_size: 1000
  memory_limit_mb: 2000

n8n:
  url: ${N8N_URL}
  split_batch_size: 5  # Critical for memory

telegram:
  bot_token: ${TELEGRAM_BOT_TOKEN}
```

**Deliverables**:
- config/config.yaml
- config/config.example.yaml
- src/utils/config.py

**Success Criteria**:
- ✅ Config loads successfully
- ✅ Environment variables override defaults
- ✅ Secrets not committed to repo

---

## Phase 2: Chunking Engine Implementation (Week 2-3)

### Objective
Build the core hybrid chunking system

### 2.1 Base Chunking Infrastructure (4 hours)

**File**: `src/chunking/base.py`
```python
from dataclasses import dataclass
from datetime import datetime
from typing import List, Dict, Any
import uuid

@dataclass
class Message:
    """Unified message schema"""
    id: str
    platform: str
    chat_id: str
    sender_id: str
    sender_name: str
    text: str
    timestamp: datetime
    reply_to_message_id: str = None
    thread_id: str = None
    metadata: Dict[str, Any] = None

@dataclass
class Chunk:
    """Chunk with metadata"""
    chunk_id: str
    messages: List[Message]
    metadata: Dict[str, Any]

    @property
    def text(self):
        """Combined text of all messages"""
        return "\n\n".join([
            f"{msg.sender_name}: {msg.text}"
            for msg in self.messages
        ])

    @property
    def timestamp_start(self):
        return min(msg.timestamp for msg in self.messages)

    @property
    def timestamp_end(self):
        return max(msg.timestamp for msg in self.messages)

class BaseChunker:
    """Base class for chunking strategies"""

    def chunk(self, messages: List[Message]) -> List[Chunk]:
        raise NotImplementedError

    def create_chunk(self, messages: List[Message], chunk_type: str, extra_metadata: Dict = None) -> Chunk:
        """Helper to create chunk with standard metadata"""
        chunk_id = str(uuid.uuid4())

        metadata = {
            'chunk_id': chunk_id,
            'chunk_type': chunk_type,
            'message_count': len(messages),
            'chat_id': messages[0].chat_id,
            'timestamp_start': min(msg.timestamp for msg in messages).isoformat(),
            'timestamp_end': max(msg.timestamp for msg in messages).isoformat(),
            'participants': list(set(msg.sender_name for msg in messages)),
        }

        if extra_metadata:
            metadata.update(extra_metadata)

        return Chunk(chunk_id=chunk_id, messages=messages, metadata=metadata)
```

**Tasks**:
- [ ] Implement Message dataclass
- [ ] Implement Chunk dataclass
- [ ] Implement BaseChunker interface
- [ ] Write unit tests

**Success Criteria**:
- ✅ Message and Chunk classes work correctly
- ✅ Unit tests pass

### 2.2 Thread-Based Chunking (3 hours)

**File**: `src/chunking/thread_chunker.py`
```python
from typing import List, Dict
from .base import BaseChunker, Message, Chunk

class ThreadChunker(BaseChunker):
    """Chunk by thread/reply chains"""

    def __init__(self, max_thread_tokens=2000):
        self.max_thread_tokens = max_thread_tokens

    def chunk(self, messages: List[Message]) -> List[Chunk]:
        """Group messages into threads"""
        threads = self._build_threads(messages)
        chunks = []

        for thread_messages in threads.values():
            chunk = self.create_chunk(
                messages=thread_messages,
                chunk_type='thread',
                extra_metadata={
                    'is_thread': len(thread_messages) > 1,
                    'thread_depth': self._calculate_thread_depth(thread_messages)
                }
            )
            chunks.append(chunk)

        return chunks

    def _build_threads(self, messages: List[Message]) -> Dict[str, List[Message]]:
        """Build thread structure from messages"""
        threads = {}
        message_map = {msg.id: msg for msg in messages}

        for msg in messages:
            # Find thread root
            root_id = self._find_thread_root(msg, message_map)

            if root_id not in threads:
                threads[root_id] = []
            threads[root_id].append(msg)

        return threads

    def _find_thread_root(self, msg: Message, message_map: Dict) -> str:
        """Traverse reply chain to find root"""
        current = msg
        while current.reply_to_message_id and current.reply_to_message_id in message_map:
            current = message_map[current.reply_to_message_id]
        return current.id

    def _calculate_thread_depth(self, thread_messages: List[Message]) -> int:
        """Calculate maximum depth of thread"""
        # Build parent-child relationships
        children = {}
        for msg in thread_messages:
            if msg.reply_to_message_id:
                children[msg.reply_to_message_id] = children.get(msg.reply_to_message_id, 0) + 1

        return max(children.values()) if children else 0
```

**Tasks**:
- [ ] Implement thread detection algorithm
- [ ] Handle edge cases (orphaned replies, cross-thread references)
- [ ] Write tests with complex thread structures
- [ ] Optimize for performance

**Test Cases**:
```python
def test_simple_thread():
    messages = [
        Message(id="1", text="Root", timestamp=dt(10, 0)),
        Message(id="2", text="Reply", reply_to="1", timestamp=dt(10, 1)),
    ]
    chunks = ThreadChunker().chunk(messages)
    assert len(chunks) == 1
    assert len(chunks[0].messages) == 2

def test_multiple_threads():
    messages = [
        Message(id="1", text="Thread 1 root"),
        Message(id="2", text="Thread 1 reply", reply_to="1"),
        Message(id="3", text="Thread 2 root"),
    ]
    chunks = ThreadChunker().chunk(messages)
    assert len(chunks) == 2
```

**Success Criteria**:
- ✅ Simple threads grouped correctly
- ✅ Deep threads (5+ levels) handled
- ✅ Orphaned replies handled gracefully
- ✅ Performance: >1000 messages/sec

### 2.3 Time-Window Clustering (3 hours)

**File**: `src/chunking/time_clusterer.py`
```python
from typing import List
from datetime import datetime, timedelta
from .base import BaseChunker, Message, Chunk

class TimeClusterer(BaseChunker):
    """Cluster messages by time windows"""

    def __init__(self, window_minutes=2, adaptive=True):
        self.window_minutes = window_minutes
        self.adaptive = adaptive

    def chunk(self, messages: List[Message]) -> List[Chunk]:
        """Group messages into time-based clusters"""
        if not messages:
            return []

        # Sort by timestamp
        sorted_messages = sorted(messages, key=lambda m: m.timestamp)

        clusters = []
        current_cluster = [sorted_messages[0]]

        for msg in sorted_messages[1:]:
            if self._should_cluster(current_cluster[-1], msg):
                current_cluster.append(msg)
            else:
                # Finalize current cluster
                chunk = self.create_chunk(
                    messages=current_cluster,
                    chunk_type='time_cluster',
                    extra_metadata={
                        'time_window_minutes': self.window_minutes,
                        'primary_sender': self._get_primary_sender(current_cluster)
                    }
                )
                clusters.append(chunk)
                current_cluster = [msg]

        # Don't forget last cluster
        if current_cluster:
            chunk = self.create_chunk(
                messages=current_cluster,
                chunk_type='time_cluster',
                extra_metadata={
                    'time_window_minutes': self.window_minutes,
                    'primary_sender': self._get_primary_sender(current_cluster)
                }
            )
            clusters.append(chunk)

        return clusters

    def _should_cluster(self, last_msg: Message, current_msg: Message) -> bool:
        """Determine if messages should be in same cluster"""
        time_diff = (current_msg.timestamp - last_msg.timestamp).total_seconds() / 60

        # Same sender within window
        if last_msg.sender_id == current_msg.sender_id and time_diff <= self.window_minutes:
            return True

        # Very quick response (<30 seconds) even if different sender
        if time_diff < 0.5:
            return True

        return False

    def _get_primary_sender(self, messages: List[Message]) -> str:
        """Get most active sender in cluster"""
        from collections import Counter
        senders = [msg.sender_name for msg in messages]
        return Counter(senders).most_common(1)[0][0]
```

**Tasks**:
- [ ] Implement time-window clustering
- [ ] Add adaptive window sizing (analyze chat velocity)
- [ ] Handle timezone issues
- [ ] Write tests for edge cases

**Success Criteria**:
- ✅ Messages clustered within time windows
- ✅ Same-sender bursts grouped together
- ✅ Quick responses (<30s) clustered regardless of sender

### 2.4 Hybrid Chunker (Orchestrator) (4 hours)

**File**: `src/chunking/hybrid_chunker.py`
```python
from typing import List
from .base import BaseChunker, Message, Chunk
from .thread_chunker import ThreadChunker
from .time_clusterer import TimeClusterer
from .semantic_splitter import SemanticSplitter
from .token_splitter import TokenSplitter

class HybridChunker(BaseChunker):
    """
    Multi-level chunking strategy:
    1. Thread-based
    2. Time-window
    3. Semantic boundaries
    4. Token limits with overlap
    """

    def __init__(self, config: dict):
        self.config = config
        self.thread_chunker = ThreadChunker(
            max_thread_tokens=config['thread_chunking']['max_thread_tokens']
        )
        self.time_clusterer = TimeClusterer(
            window_minutes=config['time_clustering']['window_minutes']
        )
        self.semantic_splitter = SemanticSplitter(
            threshold=config['semantic_boundaries']['similarity_threshold']
        )
        self.token_splitter = TokenSplitter(
            max_tokens=config['token_splitting']['max_tokens'],
            overlap_tokens=config['token_splitting']['overlap_tokens']
        )

    def chunk(self, messages: List[Message]) -> List[Chunk]:
        """Apply multi-level chunking"""
        # Level 1: Group by threads
        thread_chunks = self.thread_chunker.chunk(messages)

        final_chunks = []

        for thread_chunk in thread_chunks:
            # Level 2: Time-window clustering within thread
            time_chunks = self.time_clusterer.chunk(thread_chunk.messages)

            for time_chunk in time_chunks:
                # Level 3: Semantic boundary detection
                if self.config['semantic_boundaries']['enabled']:
                    semantic_chunks = self.semantic_splitter.split(time_chunk)
                else:
                    semantic_chunks = [time_chunk]

                for semantic_chunk in semantic_chunks:
                    # Level 4: Token splitting if needed
                    if self._exceeds_token_limit(semantic_chunk):
                        split_chunks = self.token_splitter.split(semantic_chunk)
                        final_chunks.extend(split_chunks)
                    else:
                        final_chunks.append(semantic_chunk)

        # Link related chunks
        self._link_chunks(final_chunks)

        return final_chunks

    def _exceeds_token_limit(self, chunk: Chunk) -> bool:
        """Check if chunk exceeds token limit"""
        from tiktoken import encoding_for_model
        enc = encoding_for_model("gpt-3.5-turbo")
        token_count = len(enc.encode(chunk.text))
        return token_count > self.config['token_splitting']['max_tokens']

    def _link_chunks(self, chunks: List[Chunk]):
        """Add relationships between chunks"""
        # Sort by timestamp
        sorted_chunks = sorted(chunks, key=lambda c: c.timestamp_start)

        for i, chunk in enumerate(sorted_chunks):
            if i > 0:
                chunk.metadata['previous_chunk_id'] = sorted_chunks[i-1].chunk_id
            if i < len(sorted_chunks) - 1:
                chunk.metadata['next_chunk_id'] = sorted_chunks[i+1].chunk_id
```

**Tasks**:
- [ ] Implement orchestrator logic
- [ ] Add chunk linking
- [ ] Handle configuration
- [ ] Comprehensive integration tests

**Success Criteria**:
- ✅ All levels applied in correct order
- ✅ Chunks properly linked
- ✅ Configuration respected

---

## Phase 3: Preprocessing & Telegram Integration (Week 3)

### 3.1 Update Telegram Parser (2 hours)

**File**: `src/adapters/telegram_adapter.py`
```python
import json
from typing import List, Generator
from datetime import datetime
from ..chunking.base import Message

class TelegramAdapter:
    """Convert Telegram JSON to unified Message schema"""

    def parse_export(self, file_path: str) -> Generator[Message, None, None]:
        """Stream messages from Telegram export"""
        with open(file_path, 'r', encoding='utf-8') as f:
            data = json.load(f)

            chat_info = {
                'id': data.get('id'),
                'name': data.get('name'),
                'type': data.get('type')
            }

            for msg_data in data.get('messages', []):
                yield self._convert_message(msg_data, chat_info)

    def _convert_message(self, msg_data: dict, chat_info: dict) -> Message:
        """Convert Telegram message to unified schema"""
        return Message(
            id=str(msg_data['id']),
            platform='telegram',
            chat_id=str(chat_info['id']),
            sender_id=str(msg_data.get('from_id', '')),
            sender_name=msg_data.get('from', 'Unknown'),
            text=self._extract_text(msg_data),
            timestamp=datetime.fromisoformat(msg_data['date']),
            reply_to_message_id=str(msg_data['reply_to_message_id']) if msg_data.get('reply_to_message_id') else None,
            metadata={
                'chat_name': chat_info['name'],
                'chat_type': chat_info['type'],
                'original': msg_data
            }
        )

    def _extract_text(self, msg_data: dict) -> str:
        """Extract text from message (handle different formats)"""
        text_data = msg_data.get('text', '')

        if isinstance(text_data, str):
            return text_data
        elif isinstance(text_data, list):
            # Handle rich text format
            return ''.join(
                item['text'] if isinstance(item, dict) else str(item)
                for item in text_data
            )
        return ''
```

**Tasks**:
- [ ] Update parser to use unified Message schema
- [ ] Handle all Telegram export formats
- [ ] Add error handling
- [ ] Test with real exports

**Success Criteria**:
- ✅ Parses sample exports correctly
- ✅ Handles edge cases (empty messages, media only, etc.)
- ✅ Streams large files efficiently

### 3.2 Embedding Module (3 hours)

**File**: `src/embedding/openai_embedder.py`
```python
from typing import List
import openai
from tenacity import retry, stop_after_attempt, wait_exponential

class OpenAIEmbedder:
    """Generate embeddings using OpenAI API"""

    def __init__(self, api_key: str, model='text-embedding-3-large'):
        self.client = openai.OpenAI(api_key=api_key)
        self.model = model

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=10))
    def embed(self, text: str) -> List[float]:
        """Embed single text"""
        response = self.client.embeddings.create(
            model=self.model,
            input=text
        )
        return response.data[0].embedding

    @retry(stop=stop_after_attempt(3), wait=wait_exponential(multiplier=1, min=2, max=10))
    def embed_batch(self, texts: List[str], batch_size=100) -> List[List[float]]:
        """Embed multiple texts efficiently"""
        embeddings = []

        for i in range(0, len(texts), batch_size):
            batch = texts[i:i+batch_size]
            response = self.client.embeddings.create(
                model=self.model,
                input=batch
            )
            embeddings.extend([data.embedding for data in response.data])

        return embeddings
```

**Tasks**:
- [ ] Implement OpenAI embedder
- [ ] Add retry logic for rate limits
- [ ] Implement batch processing
- [ ] Add local Ollama fallback (optional)
- [ ] Test with API

**Success Criteria**:
- ✅ Generates 3072-dim embeddings
- ✅ Handles rate limits gracefully
- ✅ Batch processing works

---

## Phase 4: Database Integration (Week 4)

### 4.1 Database Layer (4 hours)

**File**: `src/utils/database.py`
```python
import psycopg2
from psycopg2.extras import execute_values
from typing import List, Dict
from ..chunking.base import Chunk

class Database:
    """PostgreSQL + pgvector operations"""

    def __init__(self, connection_url: str):
        self.conn = psycopg2.connect(connection_url)

    def insert_chunks(self, chunks: List[Chunk], embeddings: List[List[float]]):
        """Bulk insert chunks with embeddings"""
        with self.conn.cursor() as cur:
            data = [
                (
                    chunk.chunk_id,
                    chunk.metadata['chat_id'],
                    chunk.metadata['chat_name'],
                    chunk.text,
                    embeddings[i],
                    chunk.metadata,
                    chunk.timestamp_start,
                    chunk.metadata.get('search_boost', 1.0)
                )
                for i, chunk in enumerate(chunks)
            ]

            execute_values(
                cur,
                """
                INSERT INTO message_embeddings
                (chunk_id, chat_id, chat_name, chunk_text, embedding, metadata, timestamp, search_boost)
                VALUES %s
                """,
                data
            )
            self.conn.commit()

    def search_similar(self, query_embedding: List[float], limit=10, similarity_threshold=0.7):
        """Vector similarity search"""
        with self.conn.cursor() as cur:
            cur.execute(
                """
                SELECT
                    chunk_id,
                    chat_name,
                    chunk_text,
                    metadata,
                    timestamp,
                    1 - (embedding <=> %s::vector) as similarity
                FROM message_embeddings
                WHERE 1 - (embedding <=> %s::vector) > %s
                ORDER BY embedding <=> %s::vector
                LIMIT %s
                """,
                (query_embedding, query_embedding, similarity_threshold, query_embedding, limit)
            )
            return cur.fetchall()

    def create_indexes(self):
        """Create HNSW index (run after bulk load)"""
        with self.conn.cursor() as cur:
            # HNSW index for fast vector search
            cur.execute("""
                CREATE INDEX IF NOT EXISTS message_embeddings_embedding_idx
                ON message_embeddings
                USING hnsw (embedding vector_cosine_ops)
                WITH (m = 16, ef_construction = 64);
            """)

            # Metadata indexes
            cur.execute("""
                CREATE INDEX IF NOT EXISTS message_embeddings_chat_idx
                ON message_embeddings(chat_id);

                CREATE INDEX IF NOT EXISTS message_embeddings_timestamp_idx
                ON message_embeddings(timestamp);

                CREATE INDEX IF NOT EXISTS message_embeddings_metadata_gin_idx
                ON message_embeddings USING gin(metadata);
            """)
            self.conn.commit()
```

**Tasks**:
- [ ] Implement bulk insert
- [ ] Implement vector search
- [ ] Add index creation
- [ ] Add error handling
- [ ] Write integration tests

**Success Criteria**:
- ✅ Bulk insert >1000 chunks/sec
- ✅ Vector search <200ms
- ✅ Indexes created successfully

### 4.2 End-to-End Pipeline (3 hours)

**File**: `src/pipeline.py`
```python
from typing import List
from .adapters.telegram_adapter import TelegramAdapter
from .chunking.hybrid_chunker import HybridChunker
from .embedding.openai_embedder import OpenAIEmbedder
from .utils.database import Database
from .utils.config import Config

class Pipeline:
    """End-to-end processing pipeline"""

    def __init__(self, config: Config):
        self.config = config
        self.adapter = TelegramAdapter()
        self.chunker = HybridChunker(config.get_chunking_config())
        self.embedder = OpenAIEmbedder(config.openai_api_key)
        self.db = Database(config.database_url)

    def process_export(self, export_file: str):
        """Process Telegram export end-to-end"""
        # 1. Parse messages
        messages = list(self.adapter.parse_export(export_file))
        print(f"Parsed {len(messages)} messages")

        # 2. Chunk messages
        chunks = self.chunker.chunk(messages)
        print(f"Created {len(chunks)} chunks")

        # 3. Generate embeddings
        chunk_texts = [chunk.text for chunk in chunks]
        embeddings = self.embedder.embed_batch(chunk_texts)
        print(f"Generated {len(embeddings)} embeddings")

        # 4. Store in database
        self.db.insert_chunks(chunks, embeddings)
        print(f"Inserted {len(chunks)} chunks into database")

    def query(self, question: str, limit=5):
        """Query the RAG system"""
        # Embed query
        query_embedding = self.embedder.embed(question)

        # Search
        results = self.db.search_similar(query_embedding, limit=limit)

        return results
```

**Tasks**:
- [ ] Implement end-to-end pipeline
- [ ] Add progress tracking
- [ ] Add error handling and resume capability
- [ ] Test with sample export

**Success Criteria**:
- ✅ Processes sample export (100 messages) successfully
- ✅ Can query and get relevant results
- ✅ No data loss

---

## Phase 5: Testing & Polish (Week 5)

### 5.1 Comprehensive Testing (8 hours)

**Test Suite Structure**:
```
tests/
├── unit/
│   ├── test_thread_chunker.py
│   ├── test_time_clusterer.py
│   ├── test_semantic_splitter.py
│   ├── test_token_splitter.py
│   └── test_telegram_adapter.py
├── integration/
│   ├── test_end_to_end.py
│   ├── test_database.py
│   └── test_embedding.py
└── fixtures/
    ├── sample_chat_100.json
    ├── sample_chat_1000.json
    └── sample_thread_deep.json
```

**Key Tests**:
1. Unit tests for each chunking level
2. Integration test: full pipeline
3. Performance tests: 10K messages
4. Retrieval accuracy tests: A/B vs fixed chunking
5. Edge case tests: empty messages, long threads, etc.

**Success Criteria**:
- ✅ 90%+ code coverage
- ✅ All tests pass
- ✅ Retrieval accuracy >85%

### 5.2 CLI Tool (4 hours)

**File**: `cli.py`
```python
import click
from src.pipeline import Pipeline
from src.utils.config import Config

@click.group()
def cli():
    """Talk2Telegram RAG CLI"""
    pass

@cli.command()
@click.argument('export_file')
def import_export(export_file):
    """Import Telegram export"""
    config = Config()
    pipeline = Pipeline(config)
    pipeline.process_export(export_file)
    click.echo(f"Successfully imported {export_file}")

@cli.command()
@click.argument('question')
@click.option('--limit', default=5, help='Number of results')
def query(question, limit):
    """Query chat history"""
    config = Config()
    pipeline = Pipeline(config)
    results = pipeline.query(question, limit=limit)

    for i, result in enumerate(results):
        click.echo(f"\n--- Result {i+1} (similarity: {result['similarity']:.2f}) ---")
        click.echo(f"Chat: {result['chat_name']}")
        click.echo(f"Time: {result['timestamp']}")
        click.echo(f"Text: {result['chunk_text'][:200]}...")

@cli.command()
def create_indexes():
    """Create database indexes (run after initial import)"""
    config = Config()
    db = Database(config.database_url)
    db.create_indexes()
    click.echo("Indexes created successfully")

if __name__ == '__main__':
    cli()
```

**Usage**:
```bash
# Import export
python cli.py import-export ~/Downloads/telegram_export.json

# Create indexes
python cli.py create-indexes

# Query
python cli.py query "What did John say about the delivery?"
```

**Success Criteria**:
- ✅ CLI works for basic operations
- ✅ Good error messages
- ✅ Help text clear

---

## Phase 6: Deployment & Documentation (Week 6)

### 6.1 Documentation (4 hours)

**Documents to Create**:
1. README.md - Quick start guide
2. docs/tutorials/getting-started.md
3. docs/api/python-api.md
4. docs/decisions/ - Architecture decision records

### 6.2 Deployment (4 hours)

**Options**:
1. **Self-hosted**: Docker compose
2. **Railway**: Deploy with Supabase
3. **Local**: Python virtual environment

**Docker Setup**:
```dockerfile
# Dockerfile
FROM python:3.11-slim

WORKDIR /app

COPY requirements.txt .
RUN pip install -r requirements.txt

COPY . .

CMD ["python", "cli.py"]
```

```yaml
# docker-compose.yml
version: '3.8'
services:
  postgres:
    image: ankane/pgvector
    environment:
      POSTGRES_PASSWORD: postgres
    ports:
      - "5432:5432"
    volumes:
      - pgdata:/var/lib/postgresql/data

  app:
    build: .
    environment:
      DATABASE_URL: postgresql://postgres:postgres@postgres:5432/talk2telegram
      OPENAI_API_KEY: ${OPENAI_API_KEY}
    depends_on:
      - postgres

volumes:
  pgdata:
```

**Success Criteria**:
- ✅ Can deploy locally with Docker
- ✅ Documentation clear and complete
- ✅ Others can use the system

---

## Phase 7: Multi-Platform Extension (Week 7-10, Optional)

### 7.1 WhatsApp Adapter (Week 7)
- [ ] Research WhatsApp export format
- [ ] Implement WhatsAppAdapter
- [ ] Test with sample data

### 7.2 Slack Adapter (Week 8)
- [ ] Use Slack export API
- [ ] Implement SlackAdapter
- [ ] Handle threads and channels

### 7.3 Platform Selection UI (Week 9-10)
- [ ] Simple web UI for platform selection
- [ ] Checkbox interface
- [ ] Export upload interface

---

## Success Metrics

### Technical Metrics
- **Processing Speed**: >50 messages/sec end-to-end ✅ Target
- **Search Latency**: <200ms 95th percentile ✅ Target
- **Retrieval Accuracy**: >85% relevant results ✅ Target
- **Memory Usage**: <3GB during import ✅ Target

### User Experience Metrics
- **Setup Time**: <30 minutes for first import ✅ Target
- **Query Success Rate**: >85% queries answered well ✅ Target
- **Error Recovery**: Graceful handling of API failures ✅ Target

### Code Quality Metrics
- **Test Coverage**: >80% ✅ Target
- **Documentation**: All public APIs documented ✅ Target
- **Code Style**: Passes linting ✅ Target

---

## Risk Mitigation

### High-Priority Risks

**Risk**: n8n memory overflow
**Mitigation**: Use Python preprocessing exclusively, n8n only for orchestration
**Status**: Mitigated

**Risk**: OpenAI rate limits
**Mitigation**: Exponential backoff, batch processing, Ollama fallback
**Status**: Mitigated

**Risk**: Poor chunking quality
**Mitigation**: A/B testing, configurable strategy, iterative improvement
**Status**: Requires testing

**Risk**: Database performance degradation
**Mitigation**: HNSW indexes, deferred creation, query optimization
**Status**: Mitigated

---

## Next Steps

### Immediate (This Week)
1. [ ] Reorganize repository structure
2. [ ] Set up database schema
3. [ ] Implement thread chunker
4. [ ] Write tests

### Short Term (Next 2 Weeks)
1. [ ] Complete all chunking levels
2. [ ] Integrate embeddings
3. [ ] Build end-to-end pipeline
4. [ ] Test with real Telegram export

### Medium Term (4-6 Weeks)
1. [ ] Polish CLI tool
2. [ ] Deploy to Railway
3. [ ] Complete documentation
4. [ ] A/B test chunking strategies

### Long Term (2-3 Months)
1. [ ] Add WhatsApp support
2. [ ] Add Slack support
3. [ ] Build simple UI
4. [ ] Open source release

---

## Questions & Decisions Needed

1. **Chunking Parameters**: What's optimal? (Requires A/B testing)
   - Time window: 2, 3, or 5 minutes?
   - Token limit: 500 or 1000?
   - Overlap: 10%, 15%, or 20%?

2. **Semantic Splitting**: Use embeddings or simpler heuristics?
   - Trade-off: Accuracy vs. Speed
   - Recommendation: Start simple, add embeddings if needed

3. **n8n vs. Python**: Keep n8n or pure Python?
   - Recommendation: Start with pure Python, add n8n if UI needed

4. **Deployment**: Self-hosted or Railway?
   - Depends on: Scale, budget, technical expertise
   - Recommendation: Start self-hosted, offer Railway option

5. **Open Source**: Release publicly?
   - Benefits: Community contributions, credibility
   - Considerations: Support burden, security review
   - Recommendation: Yes, with clear disclaimer and docs
