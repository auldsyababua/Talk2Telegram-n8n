# n8n Telegram RAG Implementation Plan

## Executive Summary

Building a production-ready Telegram chat RAG system using n8n workflows with sophisticated T2T2 chunking logic. This approach minimizes memory usage through batch processing, handles rate limits gracefully, and preserves conversation context across 39 work chats.

## Technical Architecture

```
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Telegram Export │────▶│ Pre-processor   │────▶│ n8n Import      │
│ JSON Files      │     │ (Python Script) │     │ Workflow        │
└─────────────────┘     └─────────────────┘     └─────────────────┘
                                                          │
                                                          ▼
┌─────────────────┐     ┌─────────────────┐     ┌─────────────────┐
│ Telegram Bot    │◀────│ n8n Search      │◀────│ PostgreSQL +    │
│ Interface       │     │ Workflow        │     │ pgvector        │
└─────────────────┘     └─────────────────┘     └─────────────────┘
```

## Version Matrix

| Component | Version | Justification |
|-----------|---------|---------------|
| n8n | 1.31.0+ | Latest stable with improved memory handling |
| PostgreSQL | 15.4 | LTS with best pgvector performance |
| pgvector | 0.6.0 | HNSW index support, stable API |
| Node.js | 20.11.0 | LTS with better memory management |
| Python | 3.11+ | For pre-processing script |

## Pre-Implementation Checklist

- [ ] PostgreSQL 15+ installed with pgvector extension
- [ ] n8n instance with 4GB+ memory allocated
- [ ] OpenAI API key with $50+ credit
- [ ] Python 3.11+ for pre-processing
- [ ] 10GB+ free disk space for processing
- [ ] Telegram Desktop for exports
- [ ] Git repository initialized

## Implementation Steps

### Phase 1: Environment Setup (30 mins)

1. **Configure PostgreSQL with pgvector**
   ```bash
   # Install pgvector extension
   CREATE EXTENSION IF NOT EXISTS vector;
   
   # Verify installation
   SELECT * FROM pg_extension WHERE extname = 'vector';
   ```
   **Verification**: Should return one row with vector extension

2. **Configure n8n memory limits**
   ```bash
   # In n8n docker-compose.yml or systemd service
   environment:
     - NODE_OPTIONS=--max-old-space-size=4096
     - EXECUTIONS_DATA_PRUNE=true
     - EXECUTIONS_DATA_MAX_AGE=168
   ```
   **Verification**: `docker logs n8n | grep "max-old-space"`

3. **Create database schema**
   ```sql
   -- Run schema.sql (see below)
   psql -U postgres -d telegram_rag -f schema.sql
   ```
   **Verification**: `\dt` should show all tables

### Phase 2: Pre-Processing Setup (45 mins)

4. **Install Python dependencies**
   ```bash
   pip install ijson psycopg2-binary tqdm
   ```
   **Verification**: `pip list | grep ijson`

5. **Deploy pre-processing script**
   ```bash
   cp src/preprocess_telegram.py ~/telegram_exports/
   chmod +x preprocess_telegram.py
   ```
   **Verification**: Script runs without errors

6. **Test with small export**
   ```bash
   python preprocess_telegram.py --input test_chat.json --output chunks/ --batch-size 100
   ```
   **Verification**: Check chunks/ directory has JSON files

### Phase 3: n8n Workflow Configuration (60 mins)

7. **Import base workflow**
   - Download workflow 3763 template
   - Import into n8n
   - Rename to "Telegram Import Workflow"
   **Verification**: Workflow appears in n8n UI

8. **Configure credentials**
   - PostgreSQL: Host, port, database, user, password
   - OpenAI: API key
   - Set up pgvector node connection
   **Verification**: Test each credential connection

9. **Modify workflow nodes**
   - Replace Gmail node with Read Binary Files
   - Update Code node with T2T2 chunking logic
   - Configure batch size to 5 in Split In Batches
   **Verification**: Manual test with 10 messages

### Phase 4: Initial Import (2-4 hours)

10. **Export Telegram chats**
    ```
    - Open Telegram Desktop
    - Settings > Advanced > Export Telegram Data
    - Format: JSON, Skip media
    - One chat at a time from 10NetZero folder
    ```
    **Verification**: result.json exists for each chat

11. **Pre-process exports**
    ```bash
    for file in exports/*.json; do
      python preprocess_telegram.py --input "$file" --output chunks/
    done
    ```
    **Verification**: chunks/ has files < 10MB each

12. **Run import workflow**
    - Set folder path in workflow
    - Enable execution logging
    - Monitor memory usage
    **Verification**: Check PostgreSQL row count

### Phase 5: Search Interface Setup (30 mins)

13. **Deploy search workflow**
    - Import search bot template
    - Configure Telegram bot webhook
    - Set up vector search parameters
    **Verification**: Bot responds to /search command

14. **Create indexes**
    ```sql
    CREATE INDEX ON message_embeddings USING hnsw (embedding vector_cosine_ops);
    VACUUM ANALYZE message_embeddings;
    ```
    **Verification**: Query performance < 100ms

### Phase 6: Monitoring Setup (20 mins)

15. **Configure monitoring**
    ```sql
    -- Create monitoring views
    CREATE VIEW import_progress AS ...
    ```
    **Verification**: View returns current stats

## Known Issues & Workarounds

1. **n8n Code node memory spike**
   - Issue: Processing >1000 items causes OOM
   - Solution: Use Split In Batches with size 5
   - Source: n8n community forum #31499

2. **pgvector HNSW build timeout**
   - Issue: Index creation fails on >1M vectors
   - Solution: Build index in segments
   - Source: pgvector GitHub #461

3. **OpenAI rate limit on batch embed**
   - Issue: 429 errors on rapid requests  
   - Solution: 1-second delay between batches
   - Source: OpenAI forum #981689

## Monitoring & Success Metrics

- Import rate: >50 messages/second
- Embedding generation: <$0.10 per 1000 messages
- Search latency: <200ms for 95th percentile
- Memory usage: <3GB during import
- Error rate: <0.1% message loss

## Contingency Plans

### Plan A Fails: n8n crashes on large files
→ Plan B: Use Python script to chunk and directly insert to PostgreSQL

### Plan A Fails: OpenAI rate limits hit
→ Plan B: Switch to Ollama nomic-embed-text (local, free)

### Plan A Fails: pgvector too slow
→ Plan B: Use Qdrant with n8n HTTP node

## Quality Gates

✓ Test with 100 messages first
✓ Verify search returns relevant results
✓ Check memory usage stays under 3GB
✓ Confirm no data loss (count messages)
✓ Validate metadata preservation