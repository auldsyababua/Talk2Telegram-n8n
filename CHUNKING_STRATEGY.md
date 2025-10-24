# Hybrid Chunking Strategy for Conversational Data

## Executive Summary

**The Challenge**: Standard document chunking (fixed 500-character chunks) fails catastrophically for conversations because:
- Messages are short and context-sparse
- Conversations have non-linear flow (replies, threads, forwards)
- Temporal clustering matters (conversation bursts)
- Critical context spans multiple messages
- Cutting mid-conversation destroys retrieval accuracy

**The Solution**: A 4-level hybrid chunking strategy inspired by Slack RAG systems (5-6% accuracy improvement):

1. **Thread-Level Chunking** - Keep complete threads together
2. **Time-Window Clustering** - Group conversation bursts (2-5 minute windows)
3. **Semantic Boundary Detection** - Split on topic changes
4. **Token-Limit Splitting** - Subdivide oversized chunks with overlap

**Key Innovation**: Chunk linking system that preserves narrative continuity across chunk boundaries using metadata tags.

## Core Problems with Standard Chunking

### Problem 1: Context Fragmentation

**Standard Chunking**:
```
Chunk 1: "John: When is the delivery coming?"
Chunk 2: "Mary: Should be Friday afternoon"
Chunk 3: "John: Perfect, thanks!"
```

**Query**: "When is the delivery coming?"
**Result**: Only finds Chunk 1, which doesn't contain the answer.

### Problem 2: Lost Temporal Context

**Standard Chunking**:
```
Chunk N: "Yes, let's do it" [No context about what "it" is]
```

**Query**: "Did we agree to move forward with the migration?"
**Result**: Can't determine what was agreed to.

### Problem 3: Thread Fragmentation

**Standard Chunking** breaks reply chains:
```
Chunk 1: "Alice: We need to discuss the Q4 budget"
Chunk 2: "  Bob: [reply] I agree, numbers look concerning"
Chunk 3: "  Carol: [reply to Bob] What's the biggest issue?"
```

**Query**: "What concerns do we have about Q4 budget?"
**Result**: Finds only Chunk 2 without full context.

## The Hybrid Chunking Strategy

### Level 1: Thread-Based Chunking

**Principle**: Threads are semantic units - keep them together

**Algorithm**:
```python
def chunk_by_thread(messages):
    threads = {}
    for msg in messages:
        if msg.is_thread_root:
            threads[msg.id] = [msg]
        elif msg.reply_to_message_id:
            thread_root = find_thread_root(msg)
            threads[thread_root].append(msg)
        else:
            threads[msg.id] = [msg]  # Standalone message

    return threads.values()
```

**Example**:
```
Thread Chunk:
├─ Alice: "We need to discuss the Q4 budget"
├─── Bob: [reply] "I agree, numbers look concerning"
├───── Carol: [reply to Bob] "What's the biggest issue?"
└───── Alice: [reply to Carol] "Hosting costs doubled"

Metadata:
{
  "chunk_type": "thread",
  "thread_root_id": 12345,
  "message_count": 4,
  "participants": ["Alice", "Bob", "Carol"],
  "timestamp_range": ["2024-10-24T10:00:00Z", "2024-10-24T10:05:32Z"]
}
```

**Edge Case Handling**:
- **Deep threads**: If thread >2000 tokens, proceed to Level 4 splitting
- **Cross-references**: If message references another thread, add link in metadata
- **Forwarded messages**: Treat as new thread unless explicit reply

### Level 2: Time-Window Clustering

**Principle**: Conversations happen in bursts - cluster messages within temporal windows

**Algorithm**:
```python
def cluster_by_time(messages, window_minutes=2):
    """
    Group messages by sender within time windows
    Based on observation that same-person rapid messages are one thought
    """
    clusters = []
    current_cluster = []

    for i, msg in enumerate(messages):
        if not current_cluster:
            current_cluster.append(msg)
            continue

        last_msg = current_cluster[-1]
        time_diff = (msg.timestamp - last_msg.timestamp).seconds / 60
        same_sender = msg.sender_id == last_msg.sender_id

        # Cluster if: same sender AND within window OR very quick response (<30s)
        if (same_sender and time_diff <= window_minutes) or time_diff < 0.5:
            current_cluster.append(msg)
        else:
            clusters.append(current_cluster)
            current_cluster = [msg]

    if current_cluster:
        clusters.append(current_cluster)

    return clusters
```

**Example**:
```
Cluster 1 (John, 10:00-10:02):
  "Hey everyone"
  "Just wanted to share the latest update"
  "Sales are up 15% this quarter"

Cluster 2 (Mary, 10:02-10:03):
  "That's fantastic news!"
  "Did the new campaign contribute to this?"

Cluster 3 (John, 10:03):
  "Yes, the email campaign was the biggest driver"

Metadata:
{
  "chunk_type": "time_cluster",
  "sender": "John",
  "message_count": 3,
  "time_window": "2 minutes",
  "timestamp": "2024-10-24T10:00:00Z",
  "likely_response_to": {
    "message_id": 12344,
    "sender": "Mary",
    "preview": "Did the new campaign contribute..."
  }
}
```

**Dynamic Window Sizing**:
- **Active conversations**: 2 minutes (rapid back-and-forth)
- **Casual chats**: 5 minutes (slower responses)
- **Async updates**: 10 minutes (status updates, notifications)
- **Auto-detect**: Analyze chat velocity to determine optimal window

### Level 3: Semantic Boundary Detection

**Principle**: Detect topic changes within time clusters

**Algorithm**:
```python
def detect_semantic_boundaries(message_cluster):
    """
    Use sentence embeddings to detect topic shifts
    Split when cosine similarity drops below threshold
    """
    embeddings = [get_embedding(msg.text) for msg in message_cluster]
    chunks = []
    current_chunk = [message_cluster[0]]

    for i in range(1, len(message_cluster)):
        similarity = cosine_similarity(embeddings[i-1], embeddings[i])

        # Topic change indicators
        topic_change = similarity < 0.7
        explicit_transition = has_transition_phrase(message_cluster[i].text)
        new_question = is_question(message_cluster[i].text)

        if topic_change or explicit_transition:
            chunks.append(current_chunk)
            current_chunk = [message_cluster[i]]
        else:
            current_chunk.append(message_cluster[i])

    if current_chunk:
        chunks.append(current_chunk)

    return chunks

def has_transition_phrase(text):
    transitions = [
        "by the way", "btw", "anyway", "also", "speaking of",
        "on another note", "changing topics", "different subject"
    ]
    return any(phrase in text.lower() for phrase in transitions)
```

**Example**:
```
Original Time Cluster:
1. "The Q4 budget looks tight"
2. "We need to cut hosting costs"
3. "Agreed, I'll review AWS spending"
4. "BTW, anyone going to the conference next week?"  ← Topic change
5. "I am! Looking forward to it"

After Semantic Split:

Chunk 3A (Budget Topic):
├─ "The Q4 budget looks tight"
├─ "We need to cut hosting costs"
└─ "Agreed, I'll review AWS spending"

Chunk 3B (Conference Topic):
├─ "BTW, anyone going to the conference next week?"
└─ "I am! Looking forward to it"

Metadata for 3A:
{
  "chunk_type": "semantic_segment",
  "topic_keywords": ["budget", "costs", "AWS"],
  "followed_by_chunk": "3B",
  "topic_change_detected": true
}
```

### Level 4: Token-Limit Splitting with Overlap

**Principle**: When chunks exceed model limits, split intelligently with overlap

**Algorithm**:
```python
def split_with_overlap(chunk, max_tokens=500, overlap_tokens=75):
    """
    Split oversized chunks while maintaining context continuity
    Overlap ensures no information loss at boundaries
    """
    messages = chunk.messages
    token_count = sum(count_tokens(msg.text) for msg in messages)

    if token_count <= max_tokens:
        return [chunk]  # No split needed

    # Split into sub-chunks with overlap
    sub_chunks = []
    current_messages = []
    current_tokens = 0
    overlap_buffer = []

    for msg in messages:
        msg_tokens = count_tokens(msg.text)

        if current_tokens + msg_tokens > max_tokens and current_messages:
            # Create chunk with metadata linking
            sub_chunks.append(create_sub_chunk(current_messages, chunk.metadata))

            # Keep last N messages for overlap (approximately overlap_tokens worth)
            overlap_buffer = current_messages[-2:]  # Last 2 messages for context
            current_messages = overlap_buffer + [msg]
            current_tokens = sum(count_tokens(m.text) for m in current_messages)
        else:
            current_messages.append(msg)
            current_tokens += msg_tokens

    if current_messages:
        sub_chunks.append(create_sub_chunk(current_messages, chunk.metadata))

    # Link sub-chunks
    for i, sub in enumerate(sub_chunks):
        sub.metadata['is_split_chunk'] = True
        sub.metadata['split_index'] = i
        sub.metadata['total_splits'] = len(sub_chunks)
        sub.metadata['parent_chunk_id'] = chunk.id
        if i > 0:
            sub.metadata['previous_chunk_id'] = sub_chunks[i-1].id
        if i < len(sub_chunks) - 1:
            sub.metadata['next_chunk_id'] = sub_chunks[i+1].id

    return sub_chunks
```

**Example**:
```
Original Chunk (800 tokens - too large):
├─ [Messages 1-15 discussing complex technical implementation]

After Token Splitting (max 500 tokens, 75 token overlap):

Sub-Chunk 1 (475 tokens):
├─ Messages 1-10
└─ Metadata: {
    "is_split_chunk": true,
    "split_index": 0,
    "total_splits": 2,
    "next_chunk_id": "chunk_xyz_1",
    "split_reason": "token_limit",
    "continuation": "See next chunk for full context"
  }

Sub-Chunk 2 (425 tokens):
├─ Messages 9-10 (overlap)  ← Repeated for continuity
├─ Messages 11-15
└─ Metadata: {
    "is_split_chunk": true,
    "split_index": 1,
    "total_splits": 2,
    "previous_chunk_id": "chunk_xyz_0",
    "split_reason": "token_limit",
    "continuation": "Continued from previous chunk"
  }
```

## Chunk Metadata Schema

Every chunk includes rich metadata for intelligent retrieval:

```json
{
  "chunk_id": "unique_identifier",
  "chunk_type": "thread|time_cluster|semantic_segment|split_chunk",
  "chat_id": "telegram_chat_id",
  "chat_name": "Engineering Team",
  "chat_type": "group|private|channel",

  "temporal": {
    "timestamp_start": "2024-10-24T10:00:00Z",
    "timestamp_end": "2024-10-24T10:05:32Z",
    "duration_seconds": 332,
    "time_of_day": "morning",
    "day_of_week": "Thursday"
  },

  "participants": [
    {"user_id": "123", "name": "Alice", "message_count": 3},
    {"user_id": "456", "name": "Bob", "message_count": 2}
  ],
  "primary_sender": "Alice",

  "structure": {
    "message_count": 5,
    "is_thread": true,
    "thread_root_id": 12345,
    "thread_depth": 3,
    "has_replies": true,
    "reply_chain": [12345, 12346, 12349]
  },

  "content": {
    "topics": ["budget", "Q4", "cost-cutting"],
    "entities": ["AWS", "hosting", "migration"],
    "has_question": true,
    "has_action_item": true,
    "has_decision": false,
    "sentiment": "concerned",
    "language": "en"
  },

  "relationships": {
    "is_split_chunk": false,
    "split_index": null,
    "total_splits": null,
    "parent_chunk_id": null,
    "previous_chunk_id": null,
    "next_chunk_id": null,
    "related_chunks": ["chunk_789", "chunk_012"],
    "cross_references": [
      {"message_id": 12340, "chunk_id": "chunk_789", "context": "Mentioned earlier decision"}
    ]
  },

  "search_boost": 1.0,
  "quality_score": 0.85
}
```

## Context Reconstruction Algorithm

When a query matches a split chunk, reconstruct full context:

```python
def reconstruct_context(matched_chunk, max_context_chunks=3):
    """
    Retrieve related chunks to provide complete narrative
    """
    context_chunks = [matched_chunk]

    # If split chunk, get siblings
    if matched_chunk.metadata.get('is_split_chunk'):
        parent_id = matched_chunk.metadata['parent_chunk_id']
        siblings = get_chunks_by_parent(parent_id)
        context_chunks.extend(siblings)

    # Get preceding chunks (temporal context)
    previous_id = matched_chunk.metadata.get('previous_chunk_id')
    if previous_id:
        previous = get_chunk(previous_id)
        context_chunks.insert(0, previous)

    # Get following chunks (for incomplete narratives)
    next_id = matched_chunk.metadata.get('next_chunk_id')
    if next_id:
        next_chunk = get_chunk(next_id)
        context_chunks.append(next_chunk)

    # Get cross-referenced chunks
    for ref in matched_chunk.metadata.get('cross_references', []):
        ref_chunk = get_chunk(ref['chunk_id'])
        context_chunks.append(ref_chunk)

    # Deduplicate and sort by timestamp
    context_chunks = deduplicate(context_chunks)
    context_chunks.sort(key=lambda c: c.timestamp_start)

    return {
        'primary_chunk': matched_chunk,
        'context_chunks': context_chunks,
        'full_narrative': combine_chunks(context_chunks)
    }
```

## Advanced Features

### 1. Q&A Pair Detection

Detect and link question-answer pairs across messages:

```python
def detect_qa_pairs(messages):
    """
    Identify likely Q&A patterns for better retrieval
    """
    qa_pairs = []

    for i, msg in enumerate(messages):
        if is_question(msg.text):
            # Look for answer in next 1-5 messages
            for j in range(i+1, min(i+6, len(messages))):
                answer_msg = messages[j]

                # Heuristics for answer detection:
                # 1. Reply to question
                # 2. By different person
                # 3. Within 5 minutes
                # 4. Not another question

                if (answer_msg.reply_to_message_id == msg.id or
                    (answer_msg.sender_id != msg.sender_id and
                     (answer_msg.timestamp - msg.timestamp).seconds < 300 and
                     not is_question(answer_msg.text))):

                    qa_pairs.append({
                        'question': msg,
                        'answer': answer_msg,
                        'confidence': calculate_qa_confidence(msg, answer_msg)
                    })
                    break

    return qa_pairs

def is_question(text):
    """Enhanced question detection"""
    indicators = [
        text.strip().endswith('?'),
        text.lower().startswith(('what', 'when', 'where', 'who', 'why', 'how', 'is', 'are', 'can', 'could', 'would', 'should', 'do', 'does', 'did')),
        re.search(r'\b(tell me|show me|explain|clarify|wondering)\b', text.lower())
    ]
    return any(indicators)
```

**Metadata Addition**:
```json
{
  "qa_pair": {
    "is_question": true,
    "answer_message_id": 12347,
    "answer_chunk_id": "chunk_xyz",
    "confidence": 0.92
  }
}
```

### 2. Action Item Detection

Identify and tag actionable items:

```python
def detect_action_items(text):
    """
    Detect tasks, deadlines, and assignments
    """
    patterns = {
        'assignment': r'\b(you should|please|can you|could you|@\w+)\b',
        'deadline': r'\b(by|before|until|deadline|due)\s+(\w+\s+\d{1,2}|tomorrow|next week)\b',
        'task': r'\b(need to|have to|must|should|todo|task|action item)\b',
        'decision': r'\b(decided|agreed|let\'s|we will|we\'ll)\b'
    }

    detected = {}
    for item_type, pattern in patterns.items():
        if re.search(pattern, text, re.IGNORECASE):
            detected[item_type] = True

    return detected
```

**Metadata Addition**:
```json
{
  "action_items": {
    "has_task": true,
    "has_deadline": true,
    "has_assignment": true,
    "deadline_text": "by Friday",
    "assigned_to": ["@alice"],
    "task_summary": "Review AWS spending"
  }
}
```

### 3. Cross-Chat References

Detect mentions of other chats/channels:

```python
def detect_cross_references(text, all_chats):
    """
    Find references to other chats for cross-context linking
    """
    references = []

    # Pattern: "in #channel-name" or "the engineering chat" or "@groupname"
    patterns = [
        r'in (#\w+|\w+\s+(?:chat|channel|group))',
        r'@(\w+)',
        r'\b(engineering|marketing|sales|support)\s+(?:chat|channel|group)\b'
    ]

    for pattern in patterns:
        matches = re.findall(pattern, text, re.IGNORECASE)
        for match in matches:
            # Try to resolve to actual chat
            chat = fuzzy_match_chat(match, all_chats)
            if chat:
                references.append({
                    'mentioned_chat_id': chat.id,
                    'mentioned_chat_name': chat.name,
                    'context': text
                })

    return references
```

### 4. Conversation Importance Scoring

Assign importance scores to boost relevant chunks:

```python
def calculate_importance_score(chunk):
    """
    Calculate importance for search ranking boost
    Higher scores = more important conversations
    """
    score = 1.0  # Base score

    # Factors that increase importance:
    if chunk.metadata['content']['has_action_item']:
        score += 0.3

    if chunk.metadata['content']['has_decision']:
        score += 0.4

    if chunk.metadata['content']['has_deadline']:
        score += 0.5

    if chunk.metadata['participants']['count'] > 3:
        score += 0.2  # Group discussions

    if chunk.metadata['structure']['thread_depth'] > 2:
        score += 0.3  # Deep discussions indicate importance

    # Recency boost (exponential decay)
    days_old = (datetime.now() - chunk.timestamp_start).days
    recency_boost = math.exp(-days_old / 30)  # Half-life of 30 days
    score += recency_boost * 0.5

    # Normalize to 1.0 - 10.0 range
    return min(max(score, 1.0), 10.0)
```

## Timeline Generation

For queries like "Create a timeline of events regarding the Y lawsuit":

```python
def generate_timeline(query, chunks):
    """
    Construct chronological narrative from matched chunks
    """
    # Get relevant chunks
    relevant = vector_search(query, chunks, top_k=50)

    # Sort chronologically
    relevant.sort(key=lambda c: c.timestamp_start)

    # Group by date
    timeline = {}
    for chunk in relevant:
        date = chunk.timestamp_start.date()
        if date not in timeline:
            timeline[date] = []
        timeline[date].append(chunk)

    # Format as timeline
    result = []
    for date, day_chunks in sorted(timeline.items()):
        result.append({
            'date': date,
            'events': [
                {
                    'time': c.timestamp_start.time(),
                    'participants': c.participants,
                    'summary': summarize_chunk(c),
                    'full_context': c.text,
                    'chunk_id': c.id
                }
                for c in day_chunks
            ]
        })

    return result
```

## Testing Strategy

### Unit Tests

```python
def test_thread_chunking():
    messages = [
        Message(id=1, text="Root message"),
        Message(id=2, text="Reply 1", reply_to=1),
        Message(id=3, text="Reply 2", reply_to=2),
        Message(id=4, text="Standalone"),
    ]

    chunks = chunk_by_thread(messages)

    assert len(chunks) == 2  # One thread, one standalone
    assert len(chunks[0].messages) == 3  # Thread has 3 messages
    assert chunks[0].metadata['is_thread'] == True
    assert chunks[1].metadata['is_thread'] == False

def test_time_window_clustering():
    messages = [
        Message(id=1, sender="Alice", timestamp=datetime(2024, 10, 24, 10, 0, 0), text="Message 1"),
        Message(id=2, sender="Alice", timestamp=datetime(2024, 10, 24, 10, 0, 30), text="Message 2"),
        Message(id=3, sender="Bob", timestamp=datetime(2024, 10, 24, 10, 5, 0), text="Message 3"),
    ]

    clusters = cluster_by_time(messages, window_minutes=2)

    assert len(clusters) == 2  # Alice's cluster and Bob's message
    assert len(clusters[0]) == 2  # Alice's two messages
    assert clusters[0][0].sender == "Alice"

def test_split_chunk_linking():
    large_chunk = create_large_chunk(1000)  # 1000 tokens

    sub_chunks = split_with_overlap(large_chunk, max_tokens=500, overlap_tokens=75)

    assert len(sub_chunks) >= 2
    assert sub_chunks[0].metadata['next_chunk_id'] == sub_chunks[1].id
    assert sub_chunks[1].metadata['previous_chunk_id'] == sub_chunks[0].id
    assert sub_chunks[1].metadata['is_split_chunk'] == True
```

### Integration Tests

```python
def test_end_to_end_chunking():
    """Test full pipeline on real Telegram export"""
    messages = load_telegram_export('test_data/sample_chat.json')

    chunks = hybrid_chunk(messages)

    # Verify no message loss
    total_messages = sum(len(c.messages) for c in chunks)
    assert total_messages >= len(messages)  # >= because of overlap

    # Verify metadata completeness
    for chunk in chunks:
        assert 'chunk_id' in chunk.metadata
        assert 'timestamp_start' in chunk.metadata
        assert 'participants' in chunk.metadata

def test_context_reconstruction():
    """Ensure split chunks can be reconstructed"""
    messages = create_long_conversation(100)
    chunks = hybrid_chunk(messages)

    # Find a split chunk
    split_chunk = next(c for c in chunks if c.metadata.get('is_split_chunk'))

    # Reconstruct context
    context = reconstruct_context(split_chunk)

    assert context['primary_chunk'] == split_chunk
    assert len(context['context_chunks']) > 1
    assert context['full_narrative']  # Complete narrative assembled
```

### A/B Testing

Compare chunking strategies on retrieval accuracy:

```python
def ab_test_chunking_strategies():
    """
    Compare hybrid vs. fixed-size chunking
    """
    test_queries = [
        "When is the delivery coming?",
        "What did we decide about the migration?",
        "Show me action items from last week"
    ]

    results = {
        'hybrid': test_strategy(hybrid_chunk, test_queries),
        'fixed_500': test_strategy(fixed_chunk_500, test_queries),
        'fixed_1000': test_strategy(fixed_chunk_1000, test_queries)
    }

    # Metrics:
    # - Relevance: Do results answer the query?
    # - Context: Is full context preserved?
    # - Ranking: Is best result in top 3?

    for strategy, metrics in results.items():
        print(f"{strategy}: relevance={metrics.relevance}, context={metrics.context_preserved}")
```

## Implementation Plan

### Phase 1: Basic Thread + Time Chunking (Week 1)
- [ ] Implement thread detection
- [ ] Implement time-window clustering
- [ ] Basic metadata schema
- [ ] Test on 1000 messages

### Phase 2: Semantic Boundaries (Week 2)
- [ ] Implement embedding-based topic detection
- [ ] Add transition phrase detection
- [ ] Test on real conversations

### Phase 3: Token Splitting + Linking (Week 3)
- [ ] Implement overlap-based splitting
- [ ] Build chunk linking system
- [ ] Implement context reconstruction

### Phase 4: Advanced Features (Week 4)
- [ ] Q&A pair detection
- [ ] Action item extraction
- [ ] Importance scoring
- [ ] Timeline generation

### Phase 5: Testing + Optimization (Week 5)
- [ ] A/B testing vs. fixed chunking
- [ ] Performance optimization
- [ ] Integration with n8n workflows

## Configuration

Chunking parameters should be configurable:

```yaml
chunking:
  strategy: hybrid  # hybrid|fixed|semantic

  thread_chunking:
    enabled: true
    max_thread_depth: 10
    max_thread_tokens: 2000

  time_clustering:
    enabled: true
    window_minutes: 2
    adaptive_window: true  # Auto-adjust based on chat velocity

  semantic_boundaries:
    enabled: true
    similarity_threshold: 0.7
    use_embeddings: true
    detect_transitions: true

  token_splitting:
    max_tokens: 500
    overlap_tokens: 75
    overlap_percentage: 15

  advanced:
    detect_qa_pairs: true
    detect_action_items: true
    detect_cross_references: true
    calculate_importance: true

  metadata:
    extract_topics: true
    extract_entities: true
    sentiment_analysis: false
```

## Performance Considerations

### Memory Efficiency
- Process messages in streaming fashion
- Don't load all chunks into memory
- Use generators for large datasets

### Speed Optimizations
- Cache embeddings for semantic detection
- Batch similarity calculations
- Parallelize independent chunk processing

### Quality vs. Speed Trade-offs
- **Fast mode**: Thread + Time only (~500 chunks/sec)
- **Balanced mode**: + Semantic boundaries (~200 chunks/sec)
- **Quality mode**: + All advanced features (~50 chunks/sec)

## Metrics & Success Criteria

### Chunking Quality Metrics
- **Context Preservation**: % of queries where full context retrieved
- **Chunk Coherence**: Average semantic similarity within chunks
- **Boundary Accuracy**: % of topic changes detected correctly
- **Link Completeness**: % of split chunks properly linked

### Target Metrics
- Context Preservation: >90%
- Retrieval Accuracy: >85% (vs. 79% for fixed chunking)
- Average Chunk Size: 300-800 tokens
- Processing Speed: >100 chunks/second

## References

- [Slack RAG Chunking (5-6% improvement)](https://dev.to/criscmd/how-i-boosted-slack-rag-accuracy-by-5-6-with-smarter-chunking-1kf9)
- [Pinecone: Chunking Strategies](https://www.pinecone.io/learn/chunking-strategies/)
- [Semantic Chunking for RAG](https://medium.com/the-ai-forum/semantic-chunking-for-rag-f4733025d5f5)
- [RAG In the Group Chat](https://blog.continua.ai/p/rag-in-the-group-chat)
