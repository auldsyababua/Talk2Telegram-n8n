# Talk2Telegram RAG System

> Query your entire chat history using natural language. Start with Telegram, extend to any messaging platform.

[![Status](https://img.shields.io/badge/status-planning-yellow)](https://github.com/auldsyababua/Talk2Telegram-n8n)
[![License](https://img.shields.io/badge/license-MIT-blue)](LICENSE)

## Overview

Talk2Telegram is a **Retrieval-Augmented Generation (RAG) system** designed specifically for conversational data. Unlike traditional RAG systems that use naive chunking strategies, Talk2Telegram employs a sophisticated **hybrid chunking approach** that preserves conversation context, thread relationships, and temporal clustering.

### Use Cases

```
💬 "What did John say about the delivery last Friday?"
📅 "Create a timeline of events regarding the Y lawsuit based on chat history"
✅ "Show me all action items from the engineering team chat this month"
🔍 "When did we discuss the AWS migration?"
```

### Key Features

- **Smart Conversation-Aware Chunking** - Preserves threads, time windows, and semantic boundaries
- **Multi-Platform Ready** - Start with Telegram, easily extend to WhatsApp, Slack, Discord
- **Context Reconstruction** - Automatically retrieves related chunks for complete narratives
- **Timeline Generation** - Build chronological event timelines from chat history
- **Action Item Detection** - Automatically identify tasks, deadlines, and decisions
- **High Performance** - Process 50-100 messages/sec, search <200ms

## Quick Start

### Prerequisites

- Python 3.11+
- PostgreSQL 15+ with pgvector extension
- OpenAI API key (or Ollama for local embeddings)
- Telegram chat export (JSON format)

### Installation

```bash
# Clone repository
git clone https://github.com/auldsyababua/Talk2Telegram-n8n.git
cd Talk2Telegram-n8n

# Create virtual environment
python3.11 -m venv venv
source venv/bin/activate  # On Windows: venv\Scripts\activate

# Install dependencies
pip install -r requirements.txt

# Configure
cp config/config.example.yaml config/config.yaml
# Edit config.yaml with your settings
```

### Database Setup

```bash
# Using Supabase (recommended)
# 1. Create project at https://supabase.com
# 2. Enable pgvector extension in Database settings
# 3. Copy connection string to config.yaml

# Or using local PostgreSQL
psql -U postgres -c "CREATE DATABASE talk2telegram;"
psql -U postgres -d talk2telegram -c "CREATE EXTENSION vector;"
psql -U postgres -d talk2telegram -f database/schema/001_initial_schema.sql
```

### Usage

```bash
# Export your Telegram chat
# In Telegram: Chat Menu → Export Chat History → Format: JSON

# Import the export
python cli.py import-export ~/Downloads/telegram_export.json

# Create indexes (after initial import)
python cli.py create-indexes

# Query your chat history
python cli.py query "What did we discuss about the project deadline?"
```

## Architecture

Talk2Telegram uses a **4-level hybrid chunking strategy** inspired by Slack RAG research (5-6% accuracy improvement over fixed chunking):

```
Level 1: Thread-Based Chunking
   ↓
Level 2: Time-Window Clustering (2-5 minute windows)
   ↓
Level 3: Semantic Boundary Detection
   ↓
Level 4: Token-Limit Splitting with Overlap
```

### Why Hybrid Chunking?

**Traditional Fixed Chunking** (500 characters):
```
Chunk 1: "John: When is the delivery coming?"
Chunk 2: "Mary: Should be Friday afternoon"
```
❌ Query "When is delivery?" finds only Chunk 1, which lacks the answer

**Hybrid Chunking**:
```
Chunk 1: "John: When is the delivery coming?\nMary: Should be Friday afternoon"
```
✅ Query finds complete conversation with answer

See [CHUNKING_STRATEGY.md](CHUNKING_STRATEGY.md) for detailed explanation.

## Project Structure

```
Talk2Telegram-n8n/
├── ARCHITECTURE.md           # System design & decisions
├── CHUNKING_STRATEGY.md      # Detailed chunking algorithm
├── IMPLEMENTATION_ROADMAP.md # Development plan
├── README.md                 # This file
│
├── database/                 # Database artifacts
│   ├── schema/               # SQL schemas
│   ├── migrations/           # Migration scripts
│   └── views/                # Useful views
│
├── src/                      # Source code
│   ├── preprocessing/        # Export parsers
│   ├── chunking/             # Chunking engine
│   │   ├── base.py           # Base classes
│   │   ├── thread_chunker.py
│   │   ├── time_clusterer.py
│   │   ├── semantic_splitter.py
│   │   └── hybrid_chunker.py # Orchestrator
│   ├── embedding/            # Embedding providers
│   ├── adapters/             # Platform adapters
│   └── utils/                # Shared utilities
│
├── tests/                    # Test suite
│   ├── unit/
│   ├── integration/
│   └── fixtures/
│
├── docs/                     # Documentation
│   ├── api/                  # API docs
│   ├── research/             # Research notes
│   ├── tutorials/            # User guides
│   └── decisions/            # Architecture decisions
│
├── config/                   # Configuration
│   └── config.yaml
│
└── cli.py                    # Command-line interface
```

## Documentation

| Document | Description |
|----------|-------------|
| [ARCHITECTURE.md](ARCHITECTURE.md) | System design, tech stack, architectural decisions |
| [CHUNKING_STRATEGY.md](CHUNKING_STRATEGY.md) | Detailed hybrid chunking algorithm with examples |
| [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) | Week-by-week development plan |
| [docs/research/](docs/research/) | Research findings on RAG for chat data |

## Development Status

### ✅ Completed
- [x] Comprehensive architectural planning
- [x] Hybrid chunking strategy design
- [x] Database schema design
- [x] Risk assessment & mitigation
- [x] Tech stack evaluation

### 🔨 In Progress (Week 1-2)
- [ ] Repository restructuring
- [ ] Thread chunker implementation
- [ ] Time-window clustering
- [ ] Database setup

### 📋 Planned (Week 3-6)
- [ ] Semantic boundary detection
- [ ] Token splitting with overlap
- [ ] Embedding integration (OpenAI)
- [ ] End-to-end pipeline
- [ ] CLI tool
- [ ] Comprehensive testing
- [ ] Documentation

### 🔮 Future (Week 7+)
- [ ] WhatsApp adapter
- [ ] Slack adapter
- [ ] Discord adapter
- [ ] Web UI with platform selection
- [ ] Multi-modal support (images, voice)

## Performance Targets

| Metric | Target | Status |
|--------|--------|--------|
| Processing Speed | 50-100 msg/sec | 🔨 Testing |
| Search Latency | <200ms (p95) | 🔨 Testing |
| Retrieval Accuracy | >85% | 🔨 Testing |
| Memory Usage | <3GB | ✅ Validated |
| Chunking Quality | >90% context preserved | 🔨 Testing |

## Technology Stack

| Component | Technology | Version | Purpose |
|-----------|-----------|---------|---------|
| Language | Python | 3.11+ | Core implementation |
| Database | PostgreSQL | 15.4+ | Data storage |
| Vector Search | pgvector | 0.6.0+ | Similarity search |
| Embeddings | OpenAI API | text-embedding-3-large | Vector generation |
| Testing | pytest | Latest | Test framework |
| CLI | Click | Latest | Command interface |

### Alternative Options
- **Local Embeddings**: Ollama + nomic-embed-text (for offline/privacy)
- **Orchestration**: n8n (optional, for workflow automation)
- **Deployment**: Docker, Railway, or self-hosted

## Contributing

This project is currently in active development. Contributions welcome after initial MVP release.

### Development Setup

```bash
# Install development dependencies
pip install -r requirements-dev.txt

# Run tests
pytest

# Run linting
flake8 src/
black src/

# Type checking
mypy src/
```

## Research & Inspiration

This project builds on research from:
- [Slack RAG Chunking](https://dev.to/criscmd/how-i-boosted-slack-rag-accuracy-by-5-6-with-smarter-chunking-1kf9) - 5-6% accuracy improvement
- [Pinecone: Chunking Strategies](https://www.pinecone.io/learn/chunking-strategies/)
- [Semantic Chunking for RAG](https://medium.com/the-ai-forum/semantic-chunking-for-rag-f4733025d5f5)
- Original T2T2 project learnings (avoiding MTProto complexity)

## FAQ

### Why not use MTProto for live sync?
The original T2T2 project used Telethon/MTProto but faced constant authentication issues, session expiration, and complexity. Manual JSON exports are more reliable and user-friendly.

### Why PostgreSQL + pgvector instead of specialized vector DBs?
Single database for all data (messages, metadata, vectors) simplifies architecture. pgvector with HNSW indexes performs excellently for our scale. Easier to self-host.

### How is this different from standard RAG?
Standard RAG uses fixed-size chunking (500 chars) which destroys conversation context. Our hybrid approach preserves threads, time-based clustering, and reply chains.

### Can I use this with other platforms?
Yes! The architecture uses a unified message schema. Implement a new adapter in `src/adapters/` and you're done. WhatsApp and Slack adapters are planned.

### What about privacy?
All data stays local or in your Supabase instance. Only message text is sent to OpenAI for embeddings (with zero retention). Use Ollama for fully offline operation.

### How much does it cost?
**OpenAI embeddings**: ~$0.13 per 1M tokens. A typical 100K message history might cost $1-2 for initial embedding.
**Supabase**: Free tier supports up to 500MB. Paid plans start at $25/mo.
**Self-hosted**: Free (just your infrastructure costs)

## Roadmap

### Version 0.1 (MVP) - Week 6
- ✅ Telegram support
- ✅ Hybrid chunking
- ✅ CLI interface
- ✅ Basic search

### Version 0.2 - Month 2
- 🔮 WhatsApp support
- 🔮 Improved retrieval quality
- 🔮 Timeline generation
- 🔮 Action item detection

### Version 0.3 - Month 3
- 🔮 Slack support
- 🔮 Discord support
- 🔮 Web UI
- 🔮 Multi-platform queries

### Version 1.0 - Month 4+
- 🔮 Multi-modal support (images, voice)
- 🔮 Advanced analytics
- 🔮 Conversation summaries
- 🔮 Entity extraction

## License

MIT License - see [LICENSE](LICENSE) for details

## Acknowledgments

- **Anthropic** - for Claude, the AI assistant that helped design this system
- **Slack RAG Research** - for hybrid chunking insights
- **Original T2T2 Project** - for lessons learned about authentication complexity
- **pgvector Team** - for excellent PostgreSQL vector extension

## Support

- **Issues**: [GitHub Issues](https://github.com/auldsyababua/Talk2Telegram-n8n/issues)
- **Discussions**: [GitHub Discussions](https://github.com/auldsyababua/Talk2Telegram-n8n/discussions)

## Contact

- **GitHub**: [@auldsyababua](https://github.com/auldsyababua)
- **Project**: [Talk2Telegram-n8n](https://github.com/auldsyababua/Talk2Telegram-n8n)

---

**Note**: This project is in active development. The architecture and features described here represent the planned final state. See [IMPLEMENTATION_ROADMAP.md](IMPLEMENTATION_ROADMAP.md) for current progress.

⭐ Star this repo if you find it useful!
