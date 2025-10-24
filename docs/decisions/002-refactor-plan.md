# Refactor Plan: Modularize & Modernize Codebase

**Branch**: `refactor/modularize-codebase`
**Date**: 2025-10-24
**Goal**: Transform existing code into clean, modular components ready to integrate with patterns from other projects

---

## Current State Assessment

### What We Have

#### ✅ KEEP & REFACTOR
1. **src/preprocessing/telegram_parser.py** (173 lines)
   - **Good**: Memory-efficient streaming (ijson), progress bars, batch processing
   - **Needs refactoring**: Hardcoded for n8n, tightly coupled, no unified message schema
   - **Action**: Split into multiple modules

2. **database/schema/001_initial_schema.sql** (164 lines)
   - **Good**: pgvector setup, basic tables, search function
   - **Needs updates**: Add chunk_relationships, platforms, update metadata schema
   - **Action**: Update and modularize

#### ❌ REMOVE / ARCHIVE
3. **docs/archive/** - Old planning docs (already archived)
   - **Action**: Keep archived, no changes needed

---

## Refactor Strategy

### Phase 1: Modularize Telegram Parser ✂️

**Goal**: Transform monolithic `telegram_parser.py` into reusable components

#### Current Structure (BEFORE):
```
src/preprocessing/telegram_parser.py
  ├─ TelegramPreprocessor class (everything in one)
  │   ├─ stream_messages()
  │   ├─ extract_chat_info()
  │   ├─ create_batch()
  │   ├─ process_file()
  │   └─ process_directory()
  └─ main() CLI
```

#### New Structure (AFTER):
```
src/
├── adapters/
│   ├── base_adapter.py          # Abstract base class
│   └── telegram_adapter.py      # Unified message schema output
│
├── preprocessing/
│   ├── stream_parser.py         # Generic JSON streaming (reusable)
│   ├── batch_processor.py       # Generic batch creation (reusable)
│   └── telegram_legacy.py       # OLD CODE (keep for reference)
│
└── utils/
    ├── file_utils.py            # File operations
    └── progress_tracker.py      # Progress bars, logging
```

#### Changes Breakdown:

**1. Create `src/adapters/base_adapter.py`** (NEW)
```python
from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime
from typing import Dict, List, Generator

@dataclass
class UnifiedMessage:
    """Unified message schema across all platforms"""
    id: str
    platform: str
    chat_id: str
    chat_name: str
    chat_type: str  # private, group, channel
    sender_id: str
    sender_name: str
    text: str
    timestamp: datetime
    reply_to_message_id: str = None
    thread_id: str = None
    metadata: Dict = None

class BaseAdapter(ABC):
    """Base class for platform-specific adapters"""

    @abstractmethod
    def parse_export(self, file_path: str) -> Generator[UnifiedMessage, None, None]:
        """Parse platform export and yield unified messages"""
        pass

    @abstractmethod
    def extract_chat_info(self, file_path: str) -> Dict:
        """Extract chat metadata"""
        pass
```

**2. Create `src/adapters/telegram_adapter.py`** (REFACTORED)
```python
from .base_adapter import BaseAdapter, UnifiedMessage
from ..preprocessing.stream_parser import StreamParser
from datetime import datetime
from typing import Dict, Generator

class TelegramAdapter(BaseAdapter):
    """Convert Telegram JSON exports to unified message schema"""

    def __init__(self):
        self.parser = StreamParser()

    def parse_export(self, file_path: str) -> Generator[UnifiedMessage, None, None]:
        """Parse Telegram export and yield unified messages"""
        chat_info = self.extract_chat_info(file_path)

        for msg_data in self.parser.stream_json_array(file_path, 'messages.item'):
            # Skip empty messages
            if not msg_data.get('text') and not msg_data.get('caption'):
                continue

            yield self._convert_to_unified(msg_data, chat_info)

    def extract_chat_info(self, file_path: str) -> Dict:
        """Extract Telegram chat metadata"""
        return self.parser.extract_fields(file_path, ['name', 'type', 'id'])

    def _convert_to_unified(self, msg_data: Dict, chat_info: Dict) -> UnifiedMessage:
        """Convert Telegram message format to unified schema"""
        return UnifiedMessage(
            id=str(msg_data['id']),
            platform='telegram',
            chat_id=str(chat_info['id']),
            chat_name=chat_info['name'],
            chat_type=chat_info['type'],
            sender_id=str(msg_data.get('from_id', '')),
            sender_name=msg_data.get('from', 'Unknown'),
            text=msg_data.get('text') or msg_data.get('caption', ''),
            timestamp=datetime.fromisoformat(msg_data['date']),
            reply_to_message_id=str(msg_data['reply_to_message_id']) if msg_data.get('reply_to_message_id') else None,
            metadata={
                'media_type': msg_data.get('media_type'),
                'has_file': bool(msg_data.get('file')),
                'sticker_emoji': msg_data.get('sticker', {}).get('emoji') if 'sticker' in msg_data else None,
                'forwarded_from': msg_data.get('forwarded_from')
            }
        )
```

**3. Create `src/preprocessing/stream_parser.py`** (EXTRACTED)
```python
import ijson
from typing import Generator, Dict, List

class StreamParser:
    """Generic JSON streaming parser (platform-agnostic)"""

    def stream_json_array(self, file_path: str, json_path: str) -> Generator[Dict, None, None]:
        """
        Stream items from a JSON array without loading entire file

        Args:
            file_path: Path to JSON file
            json_path: Path to array in JSON (e.g., 'messages.item')
        """
        with open(file_path, 'rb') as file:
            parser = ijson.items(file, json_path)
            for item in parser:
                yield item

    def extract_fields(self, file_path: str, field_names: List[str]) -> Dict:
        """
        Extract specific fields from JSON without loading entire file

        Args:
            file_path: Path to JSON file
            field_names: List of top-level field names to extract
        """
        with open(file_path, 'rb') as file:
            parser = ijson.parse(file)
            result = {}

            for prefix, event, value in parser:
                if prefix in field_names:
                    result[prefix] = value

                # Early exit if we have all fields
                if len(result) == len(field_names):
                    break

            return result

    def count_items(self, file_path: str, json_path: str) -> int:
        """Count items in JSON array efficiently"""
        count = 0
        for _ in self.stream_json_array(file_path, json_path):
            count += 1
        return count
```

**4. Create `src/preprocessing/batch_processor.py`** (EXTRACTED)
```python
from pathlib import Path
from datetime import datetime
from typing import List, Dict
import json

class BatchProcessor:
    """Generic batch creation and writing (platform-agnostic)"""

    def __init__(self, batch_size: int = 1000):
        self.batch_size = batch_size

    def create_batch(self, items: List, batch_id: str, metadata: Dict = None) -> Dict:
        """Create a batch with metadata"""
        batch = {
            'batch_id': batch_id,
            'items': items,
            'item_count': len(items),
            'created_at': datetime.now().isoformat()
        }

        if metadata:
            batch['metadata'] = metadata

        return batch

    def write_batch(self, batch: Dict, output_dir: str, filename: str):
        """Write batch to disk as JSON"""
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)

        filepath = output_path / filename
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(batch, f, ensure_ascii=False, indent=2)

    def batch_items(self, items: List, batch_size: int = None) -> List[List]:
        """Split items into batches"""
        size = batch_size or self.batch_size
        return [items[i:i+size] for i in range(0, len(items), size)]
```

**5. Create `src/utils/progress_tracker.py`** (EXTRACTED)
```python
from tqdm import tqdm
from typing import Callable, Iterable

class ProgressTracker:
    """Progress tracking utilities"""

    @staticmethod
    def track_iterable(iterable: Iterable, total: int = None, desc: str = "Processing"):
        """Wrap iterable with progress bar"""
        return tqdm(iterable, total=total, desc=desc)

    @staticmethod
    def track_function(func: Callable, items: List, desc: str = "Processing"):
        """Execute function on items with progress tracking"""
        results = []
        with tqdm(total=len(items), desc=desc) as pbar:
            for item in items:
                result = func(item)
                results.append(result)
                pbar.update(1)
        return results
```

**6. Keep `src/preprocessing/telegram_legacy.py`** (RENAMED)
```bash
# Just rename the old file for reference
mv src/preprocessing/telegram_parser.py src/preprocessing/telegram_legacy.py
```

---

### Phase 2: Update Database Schema 🗄️

**Goal**: Add new tables for advanced chunking and multi-platform support

#### Changes to `database/schema/001_initial_schema.sql`:

**1. Add platforms table**
```sql
-- NEW TABLE: Platform registry
CREATE TABLE IF NOT EXISTS platforms (
    platform_id SERIAL PRIMARY KEY,
    platform_name VARCHAR(50) UNIQUE NOT NULL, -- telegram, whatsapp, slack, discord
    enabled BOOLEAN DEFAULT true,
    config JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Seed data
INSERT INTO platforms (platform_name, enabled) VALUES
    ('telegram', true),
    ('whatsapp', false),
    ('slack', false),
    ('discord', false)
ON CONFLICT (platform_name) DO NOTHING;
```

**2. Add chunk_relationships table**
```sql
-- NEW TABLE: Track relationships between chunks
CREATE TABLE IF NOT EXISTS chunk_relationships (
    id SERIAL PRIMARY KEY,
    chunk_id VARCHAR(255) REFERENCES message_embeddings(chunk_id),
    related_chunk_id VARCHAR(255) REFERENCES message_embeddings(chunk_id),
    relationship_type VARCHAR(50) NOT NULL, -- 'split_sibling', 'temporal_next', 'thread_related', 'cross_reference'
    confidence FLOAT DEFAULT 1.0,
    metadata JSONB DEFAULT '{}',
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(chunk_id, related_chunk_id, relationship_type)
);

CREATE INDEX idx_chunk_relationships_chunk ON chunk_relationships(chunk_id);
CREATE INDEX idx_chunk_relationships_related ON chunk_relationships(related_chunk_id);
CREATE INDEX idx_chunk_relationships_type ON chunk_relationships(relationship_type);
```

**3. Update message_embeddings metadata schema**
```sql
-- Add comment documenting metadata schema
COMMENT ON COLUMN message_embeddings.metadata IS 'Expected JSONB structure:
{
  "chunk_type": "thread|time_cluster|semantic_segment|split_chunk",
  "temporal": {
    "timestamp_start": "ISO8601",
    "timestamp_end": "ISO8601",
    "duration_seconds": int
  },
  "participants": [{"user_id": str, "name": str, "message_count": int}],
  "structure": {
    "message_count": int,
    "is_thread": bool,
    "thread_root_id": str,
    "thread_depth": int
  },
  "content": {
    "topics": [str],
    "has_question": bool,
    "has_action_item": bool,
    "has_decision": bool
  },
  "relationships": {
    "is_split_chunk": bool,
    "split_index": int,
    "total_splits": int,
    "parent_chunk_id": str,
    "previous_chunk_id": str,
    "next_chunk_id": str
  }
}';
```

**4. Create new schema file** `database/schema/002_add_relationships.sql`

---

### Phase 3: Borrow Patterns from Other Projects 🎨

**Goal**: Implement proven patterns we researched

#### 1. Conversation Mapper (from vectara/ragtime)

**File**: `src/utils/conversation_mapper.py` (NEW)
```python
import sqlite3
from datetime import datetime
from typing import List

class ConversationMapper:
    """
    Map platform conversation threads to internal chunk IDs
    Pattern inspired by vectara/ragtime
    """

    def __init__(self, db_path: str = 'data/conversation_map.db'):
        self.conn = sqlite3.connect(db_path)
        self._create_tables()

    def _create_tables(self):
        self.conn.execute("""
            CREATE TABLE IF NOT EXISTS conversation_map (
                platform TEXT NOT NULL,
                platform_thread_id TEXT NOT NULL,
                internal_chunk_id TEXT NOT NULL,
                created_at TIMESTAMP DEFAULT CURRENT_TIMESTAMP,
                PRIMARY KEY (platform, platform_thread_id, internal_chunk_id)
            )
        """)
        self.conn.commit()

    def map_thread_to_chunks(self, platform: str, thread_id: str, chunk_ids: List[str]):
        """Store relationship between platform thread and our chunks"""
        for chunk_id in chunk_ids:
            self.conn.execute(
                "INSERT OR IGNORE INTO conversation_map VALUES (?, ?, ?, ?)",
                (platform, thread_id, chunk_id, datetime.now())
            )
        self.conn.commit()

    def get_chunks_for_thread(self, platform: str, thread_id: str) -> List[str]:
        """Retrieve all chunks belonging to a conversation thread"""
        cursor = self.conn.execute(
            "SELECT internal_chunk_id FROM conversation_map WHERE platform=? AND platform_thread_id=?",
            (platform, thread_id)
        )
        return [row[0] for row in cursor.fetchall()]
```

#### 2. Enhanced Thread Detector (from DmitriiK/telegram_rag_search)

**File**: `src/chunking/thread_detector.py` (NEW)
```python
from typing import Dict, List
from ..adapters.base_adapter import UnifiedMessage

class ThreadDetector:
    """
    Build discussion trees from message reply chains
    Inspired by DmitriiK/telegram_rag_search approach
    """

    def build_discussion_tree(self, messages: List[UnifiedMessage]) -> Dict:
        """
        Build topic tree from explicit parent-child reply links
        Returns dict mapping thread_root_id -> thread_info
        """
        threads = {}
        message_map = {msg.id: msg for msg in messages}

        for msg in messages:
            # Find ultimate root of reply chain
            root = self._find_thread_root(msg, message_map)
            root_id = root.id

            if root_id not in threads:
                threads[root_id] = {
                    'root': root,
                    'messages': [],
                    'depth': 0,
                    'participants': set()
                }

            threads[root_id]['messages'].append(msg)
            threads[root_id]['participants'].add(msg.sender_id)

            # Calculate depth
            depth = self._calculate_depth(msg, message_map)
            threads[root_id]['depth'] = max(threads[root_id]['depth'], depth)

        # Convert sets to lists for JSON serialization
        for thread in threads.values():
            thread['participants'] = list(thread['participants'])

        return threads

    def _find_thread_root(self, msg: UnifiedMessage, message_map: Dict) -> UnifiedMessage:
        """Traverse reply chain to find root message"""
        current = msg
        chain = []

        while current.reply_to_message_id and current.reply_to_message_id in message_map:
            current = message_map[current.reply_to_message_id]
            chain.append(current)

            # Prevent infinite loops
            if len(chain) > 100:
                break

        return current

    def _calculate_depth(self, msg: UnifiedMessage, message_map: Dict) -> int:
        """Calculate depth of message in thread"""
        depth = 0
        current = msg

        while current.reply_to_message_id and current.reply_to_message_id in message_map:
            depth += 1
            current = message_map[current.reply_to_message_id]

            if depth > 100:  # Safety limit
                break

        return depth
```

#### 3. Event-Driven Pipeline (from groupultra/telegram-search)

**File**: `src/pipeline/event_pipeline.py` (NEW)
```python
from pyee import EventEmitter
from typing import List, Callable

class EventPipeline:
    """
    Event-driven processing pipeline
    Inspired by groupultra/telegram-search architecture
    """

    def __init__(self):
        self.event_bus = EventEmitter()
        self.handlers = {}

    def on(self, event_name: str, handler: Callable):
        """Register event handler"""
        self.event_bus.on(event_name, handler)
        self.handlers[event_name] = handler

    def emit(self, event_name: str, *args, **kwargs):
        """Emit event"""
        self.event_bus.emit(event_name, *args, **kwargs)

    def setup_rag_pipeline(self):
        """Setup standard RAG processing pipeline"""
        # This will be implemented with actual handlers
        # from chunking, embedding, and storage modules
        pass
```

---

### Phase 4: Clean Directory Structure 🧹

**Goal**: Organize codebase for easy navigation

#### New Directory Tree:
```
Talk2Telegram-n8n/
├── ARCHITECTURE.md
├── CHUNKING_STRATEGY.md
├── IMPLEMENTATION_ROADMAP.md
├── README.md
├── requirements.txt                    # NEW
├── requirements-dev.txt                # NEW
├── .gitignore                          # NEW
├── setup.py                            # NEW (optional)
│
├── database/
│   ├── schema/
│   │   ├── 001_initial_schema.sql      # UPDATED
│   │   └── 002_add_relationships.sql   # NEW
│   ├── migrations/
│   │   └── README.md
│   └── views/
│       └── README.md
│
├── src/
│   ├── __init__.py                     # NEW
│   ├── adapters/
│   │   ├── __init__.py                 # NEW
│   │   ├── base_adapter.py             # NEW
│   │   └── telegram_adapter.py         # NEW (refactored)
│   │
│   ├── preprocessing/
│   │   ├── __init__.py                 # NEW
│   │   ├── stream_parser.py            # NEW (extracted)
│   │   ├── batch_processor.py          # NEW (extracted)
│   │   └── telegram_legacy.py          # RENAMED (old code)
│   │
│   ├── chunking/                       # NEW MODULES
│   │   ├── __init__.py
│   │   ├── base.py                     # From IMPLEMENTATION_ROADMAP
│   │   ├── thread_chunker.py           # From IMPLEMENTATION_ROADMAP
│   │   ├── thread_detector.py          # NEW (from DmitriiK pattern)
│   │   ├── time_clusterer.py           # From IMPLEMENTATION_ROADMAP
│   │   ├── semantic_splitter.py        # From IMPLEMENTATION_ROADMAP
│   │   ├── token_splitter.py           # From IMPLEMENTATION_ROADMAP
│   │   └── hybrid_chunker.py           # From IMPLEMENTATION_ROADMAP
│   │
│   ├── embedding/
│   │   ├── __init__.py                 # NEW
│   │   ├── base_embedder.py            # NEW
│   │   ├── openai_embedder.py          # From IMPLEMENTATION_ROADMAP
│   │   └── ollama_embedder.py          # From IMPLEMENTATION_ROADMAP (optional)
│   │
│   ├── pipeline/
│   │   ├── __init__.py                 # NEW
│   │   ├── event_pipeline.py           # NEW (from groupultra pattern)
│   │   └── rag_pipeline.py             # NEW (main orchestrator)
│   │
│   └── utils/
│       ├── __init__.py                 # NEW
│       ├── config.py                   # From IMPLEMENTATION_ROADMAP
│       ├── database.py                 # From IMPLEMENTATION_ROADMAP
│       ├── conversation_mapper.py      # NEW (from vectara pattern)
│       ├── file_utils.py               # NEW (extracted)
│       ├── progress_tracker.py         # NEW (extracted)
│       └── logger.py                   # NEW
│
├── tests/
│   ├── __init__.py
│   ├── unit/
│   │   ├── test_telegram_adapter.py    # NEW
│   │   ├── test_stream_parser.py       # NEW
│   │   ├── test_thread_detector.py     # NEW
│   │   └── ...
│   ├── integration/
│   │   └── test_end_to_end.py
│   └── fixtures/
│       ├── sample_telegram_export.json # NEW
│       └── ...
│
├── scripts/
│   ├── create_schema.sh                # NEW
│   └── run_tests.sh                    # NEW
│
├── config/
│   ├── config.yaml                     # From IMPLEMENTATION_ROADMAP
│   └── config.example.yaml
│
├── data/                               # NEW (gitignored)
│   ├── exports/                        # User exports go here
│   ├── batches/                        # Processed batches
│   └── conversation_map.db             # SQLite mapping
│
├── docs/
│   ├── archive/
│   ├── research/
│   ├── api/
│   ├── tutorials/
│   └── decisions/
│       ├── 001-build-from-scratch.md
│       └── 002-refactor-approach.md    # NEW (this document)
│
└── cli.py                              # From IMPLEMENTATION_ROADMAP
```

---

## Execution Plan

### Step 1: Create New Branch
```bash
git checkout -b refactor/modularize-codebase
```

### Step 2: Create Package Structure
```bash
# Create __init__.py files
touch src/__init__.py
touch src/adapters/__init__.py
touch src/preprocessing/__init__.py
touch src/chunking/__init__.py
touch src/embedding/__init__.py
touch src/pipeline/__init__.py
touch src/utils/__init__.py
touch tests/__init__.py

# Create data directories
mkdir -p data/{exports,batches}

# Create config files
touch requirements.txt
touch requirements-dev.txt
touch .gitignore
```

### Step 3: Rename Old Code
```bash
mv src/preprocessing/telegram_parser.py src/preprocessing/telegram_legacy.py
```

### Step 4: Create New Modules (in order)

1. **Core abstractions** (no dependencies)
   - `src/adapters/base_adapter.py`
   - `src/preprocessing/stream_parser.py`
   - `src/preprocessing/batch_processor.py`
   - `src/utils/file_utils.py`
   - `src/utils/progress_tracker.py`

2. **Adapters** (depend on base classes)
   - `src/adapters/telegram_adapter.py`

3. **Chunking foundation** (depend on adapters)
   - `src/chunking/base.py`
   - `src/chunking/thread_detector.py`

4. **Utilities** (supporting modules)
   - `src/utils/conversation_mapper.py`
   - `src/utils/logger.py`

5. **Pipeline** (orchestration)
   - `src/pipeline/event_pipeline.py`

### Step 5: Update Database Schema
```bash
# Create new migration
cp database/schema/001_initial_schema.sql database/schema/001_initial_schema.sql.bak
# Edit 001_initial_schema.sql with new tables
# Create 002_add_relationships.sql
```

### Step 6: Create Configuration Files

**requirements.txt**:
```
# Core dependencies
python>=3.11
psycopg2-binary>=2.9.0
ijson>=3.2.0
tqdm>=4.65.0
pyyaml>=6.0
python-dotenv>=1.0.0

# Embeddings
openai>=1.0.0
tiktoken>=0.5.0

# Events
pyee>=11.0.0

# Optional: Local embeddings
# ollama>=0.1.0
```

**requirements-dev.txt**:
```
-r requirements.txt

# Testing
pytest>=7.4.0
pytest-cov>=4.1.0
pytest-asyncio>=0.21.0

# Code quality
black>=23.0.0
flake8>=6.0.0
mypy>=1.5.0
isort>=5.12.0

# Documentation
mkdocs>=1.5.0
mkdocs-material>=9.4.0
```

**.gitignore**:
```
# Python
__pycache__/
*.py[cod]
*$py.class
*.so
.Python
venv/
env/
ENV/

# IDE
.vscode/
.idea/
*.swp

# Data
data/exports/*
data/batches/*
!data/exports/.gitkeep
!data/batches/.gitkeep

# Database
*.db
*.sqlite

# Config
config/config.yaml
.env

# Logs
*.log

# Testing
.pytest_cache/
.coverage
htmlcov/
```

### Step 7: Write Tests

Create test fixtures and basic tests for new modules:
- `tests/fixtures/sample_telegram_export.json`
- `tests/unit/test_telegram_adapter.py`
- `tests/unit/test_stream_parser.py`
- `tests/unit/test_thread_detector.py`

### Step 8: Update Documentation

Create `docs/decisions/002-refactor-approach.md` (this document)

---

## Success Criteria

### ✅ Phase 1 Complete When:
- [ ] All new modules created and pass basic tests
- [ ] Old code moved to `telegram_legacy.py`
- [ ] TelegramAdapter outputs UnifiedMessage objects
- [ ] StreamParser handles large files efficiently
- [ ] Tests pass: `pytest tests/unit/`

### ✅ Phase 2 Complete When:
- [ ] Database schema updated with new tables
- [ ] Migration script tested on clean database
- [ ] chunk_relationships table working

### ✅ Phase 3 Complete When:
- [ ] ConversationMapper working with SQLite
- [ ] ThreadDetector builds discussion trees
- [ ] EventPipeline can emit and handle events

### ✅ Phase 4 Complete When:
- [ ] All `__init__.py` files created
- [ ] requirements.txt complete and tested
- [ ] .gitignore configured
- [ ] Directory structure clean
- [ ] Old code archived but accessible

---

## Timeline

- **Day 1**: Create branch, package structure, refactor telegram_parser → 3 modules
- **Day 2**: Update database schema, create borrowed patterns (ConversationMapper, ThreadDetector, EventPipeline)
- **Day 3**: Write tests, update documentation, clean up

**Total**: 3 days to complete refactor

---

## Notes

- Keep `telegram_legacy.py` as reference but don't import it
- New code should use type hints everywhere
- Follow Google Python Style Guide
- Every module should have docstrings
- Add tests as we create modules (TDD approach)

---

## Next Steps After Refactor

Once refactor is complete, we'll be ready to:
1. Implement thread_chunker.py (Week 2 of IMPLEMENTATION_ROADMAP)
2. Implement time_clusterer.py
3. Build out the full chunking pipeline
4. Integrate embeddings
5. Connect to database

The refactor gives us a clean foundation to build on.
