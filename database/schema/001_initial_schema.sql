-- n8n Telegram RAG Database Schema for Supabase
-- Extends existing T2T2 schema with enhanced chunking support

-- Note: pgvector extension already enabled in Supabase
-- Existing tables: telegram_files, user_sessions

-- IMPORTANT: The existing telegram_files table can be reused for chunks
-- It already has: content_embedding vector(1536), telegram_* fields, metadata JSONB
-- We'll store chunks there with file_type = 'message_chunk'

-- Optional: Create view for easier chunk queries
CREATE TABLE IF NOT EXISTS messages (
    id BIGSERIAL PRIMARY KEY,
    chat_id BIGINT NOT NULL,
    chat_name VARCHAR(255) NOT NULL,
    chat_type VARCHAR(50), -- private, group, channel
    message_id BIGINT NOT NULL,
    sender_id BIGINT,
    sender_name VARCHAR(255),
    text TEXT,
    date TIMESTAMP WITH TIME ZONE NOT NULL,
    reply_to_message_id BIGINT,
    has_media BOOLEAN DEFAULT FALSE,
    media_type VARCHAR(50),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    UNIQUE(chat_id, message_id)
);

-- Message embeddings table with chunks
CREATE TABLE IF NOT EXISTS message_embeddings (
    id BIGSERIAL PRIMARY KEY,
    chunk_id VARCHAR(255) UNIQUE NOT NULL,
    chunk_text TEXT NOT NULL,
    embedding vector(3072), -- OpenAI text-embedding-3-large dimensions
    
    -- Metadata as JSONB for flexibility
    metadata JSONB NOT NULL DEFAULT '{}',
    
    -- Denormalized fields for performance
    chat_name VARCHAR(255) NOT NULL,
    chat_id BIGINT NOT NULL,
    primary_sender VARCHAR(255),
    timestamp TIMESTAMP WITH TIME ZONE NOT NULL,
    
    -- Search optimization
    search_boost FLOAT DEFAULT 1.0,
    is_canonical BOOLEAN DEFAULT TRUE,
    
    -- Processing metadata
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    vector_model VARCHAR(50) DEFAULT 'text-embedding-3-large',
    
    -- Indexes will be created after bulk insert
    CHECK (search_boost > 0 AND search_boost <= 10)
);

-- Processing state tracking
CREATE TABLE IF NOT EXISTS processing_state (
    id SERIAL PRIMARY KEY,
    chat_id BIGINT NOT NULL,
    chat_name VARCHAR(255) NOT NULL,
    last_processed_message_id BIGINT,
    total_messages INTEGER DEFAULT 0,
    total_chunks INTEGER DEFAULT 0,
    status VARCHAR(50) DEFAULT 'pending', -- pending, processing, completed, failed
    started_at TIMESTAMP WITH TIME ZONE,
    completed_at TIMESTAMP WITH TIME ZONE,
    error_message TEXT,
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    updated_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Import batches for tracking
CREATE TABLE IF NOT EXISTS import_batches (
    id SERIAL PRIMARY KEY,
    batch_id VARCHAR(255) UNIQUE NOT NULL,
    source_file VARCHAR(500),
    total_messages INTEGER,
    processed_messages INTEGER DEFAULT 0,
    failed_messages INTEGER DEFAULT 0,
    status VARCHAR(50) DEFAULT 'pending',
    started_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP,
    completed_at TIMESTAMP WITH TIME ZONE,
    metadata JSONB DEFAULT '{}'
);

-- Search history for analytics
CREATE TABLE IF NOT EXISTS search_history (
    id SERIAL PRIMARY KEY,
    query TEXT NOT NULL,
    result_count INTEGER,
    top_score FLOAT,
    response_time_ms INTEGER,
    user_id VARCHAR(255),
    created_at TIMESTAMP WITH TIME ZONE DEFAULT CURRENT_TIMESTAMP
);

-- Indexes (create AFTER bulk insert for performance)
-- Run these after initial import:
/*
CREATE INDEX idx_messages_chat_date ON messages(chat_id, date DESC);
CREATE INDEX idx_messages_sender ON messages(sender_id);
CREATE INDEX idx_embeddings_chat ON message_embeddings(chat_id);
CREATE INDEX idx_embeddings_timestamp ON message_embeddings(timestamp DESC);
CREATE INDEX idx_embeddings_metadata ON message_embeddings USING GIN(metadata);

-- HNSW index for vector similarity search (create after data load)
-- CREATE INDEX idx_embeddings_vector ON message_embeddings 
-- USING hnsw (embedding vector_cosine_ops)
-- WITH (m = 16, ef_construction = 64);
*/

-- Helpful views
CREATE OR REPLACE VIEW import_progress AS
SELECT 
    ps.chat_name,
    ps.total_messages,
    ps.total_chunks,
    ps.status,
    ps.started_at,
    ps.completed_at,
    CASE 
        WHEN ps.total_messages > 0 
        THEN ROUND((ps.total_chunks::FLOAT / ps.total_messages) * 100, 2)
        ELSE 0 
    END as completion_percentage,
    COUNT(DISTINCT me.id) as actual_chunks
FROM processing_state ps
LEFT JOIN message_embeddings me ON ps.chat_id = me.chat_id
GROUP BY ps.id, ps.chat_name, ps.total_messages, ps.total_chunks, 
         ps.status, ps.started_at, ps.completed_at;

-- Function for similarity search
CREATE OR REPLACE FUNCTION search_messages(
    query_embedding vector(3072),
    match_count INT DEFAULT 10,
    similarity_threshold FLOAT DEFAULT 0.7
)
RETURNS TABLE (
    chunk_id VARCHAR,
    chunk_text TEXT,
    metadata JSONB,
    similarity FLOAT
) AS $$
BEGIN
    RETURN QUERY
    SELECT 
        me.chunk_id,
        me.chunk_text,
        me.metadata,
        1 - (me.embedding <=> query_embedding) as similarity
    FROM message_embeddings me
    WHERE 1 - (me.embedding <=> query_embedding) > similarity_threshold
    ORDER BY me.embedding <=> query_embedding
    LIMIT match_count;
END;
$$ LANGUAGE plpgsql;

-- Monitoring queries
COMMENT ON TABLE messages IS 'Raw Telegram messages - may not need if only using chunks';
COMMENT ON TABLE message_embeddings IS 'Main table for RAG - contains chunks with embeddings';
COMMENT ON TABLE processing_state IS 'Track import progress per chat';
COMMENT ON TABLE import_batches IS 'Track batch import jobs from n8n';
COMMENT ON TABLE search_history IS 'Analytics on search usage';