# n8n Telegram RAG

This project implements a sophisticated Telegram chat history RAG (Retrieval-Augmented Generation) system using n8n workflows, based on the T2T2 chunking strategy.

## Overview

Converts Telegram chat exports (JSON format) into searchable vector embeddings with advanced context preservation for multi-threaded conversations.

## Features

- **Smart Chunking**: Groups messages by sender within 2-minute windows
- **Reply Chain Preservation**: Maintains conversation threads
- **Question-Answer Linking**: Detects likely Q&A pairs across messages
- **Cross-Chat References**: Tracks mentions of other chats/channels
- **Multi-Modal Support**: Handles text, media captions, stickers
- **Work Context Awareness**: Tags action items, deadlines, decisions

## Workflows

### 1. Initial Import Workflow (`telegram-import-workflow.json`)
Based on workflow 3763, processes Telegram JSON exports and creates vector embeddings.

### 2. Ongoing Sync Workflow (`telegram-sync-workflow.json`)
Polls for new messages and incrementally updates the vector database.

### 3. Search Bot Workflow (`telegram-search-bot.json`)
Telegram bot interface for querying the indexed chat history.

## Setup

1. Import the workflows into n8n
2. Configure credentials:
   - PostgreSQL with pgvector extension
   - OpenAI API (for embeddings)
   - Telegram Bot Token
3. Create required database tables (see `schema.sql`)
4. Export Telegram chats as JSON
5. Run the import workflow

## Directory Structure

```
n8n-telegram-rag/
├── workflows/
│   ├── telegram-import-workflow.json
│   ├── telegram-sync-workflow.json
│   └── telegram-search-bot.json
├── src/
│   ├── chunking-logic.js
│   └── utils.js
├── docs/
│   └── chunking-strategy.md
├── schema.sql
└── README.md
```