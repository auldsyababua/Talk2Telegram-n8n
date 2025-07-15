#!/usr/bin/env python3
"""
Pre-process large Telegram export JSON files for n8n ingestion.
Handles memory-efficient streaming and batching.
"""

import json
import ijson
import argparse
import os
from datetime import datetime
from pathlib import Path
from typing import List, Dict, Generator
import hashlib
from tqdm import tqdm

class TelegramPreprocessor:
    def __init__(self, batch_size: int = 1000):
        self.batch_size = batch_size
        self.total_messages = 0
        self.total_batches = 0
        
    def stream_messages(self, file_path: str) -> Generator[Dict, None, None]:
        """Stream messages from large JSON file without loading into memory."""
        print(f"Streaming messages from {file_path}...")
        
        with open(file_path, 'rb') as file:
            parser = ijson.items(file, 'messages.item')
            
            for message in parser:
                # Skip empty messages
                if not message.get('text') and not message.get('caption'):
                    continue
                    
                # Extract relevant fields
                yield {
                    'id': message.get('id'),
                    'date': message.get('date'),
                    'from': message.get('from'),
                    'from_id': message.get('from_id'),
                    'text': message.get('text') or message.get('caption', ''),
                    'reply_to_message_id': message.get('reply_to_message_id'),
                    'media_type': message.get('media_type'),
                    'file': message.get('file'),
                    'sticker_emoji': message.get('sticker', {}).get('emoji') if 'sticker' in message else None,
                    'forwarded_from': message.get('forwarded_from')
                }
                
    def extract_chat_info(self, file_path: str) -> Dict:
        """Extract chat metadata from export file."""
        with open(file_path, 'rb') as file:
            parser = ijson.parse(file)
            chat_info = {}
            
            for prefix, event, value in parser:
                if prefix == 'name':
                    chat_info['name'] = value
                elif prefix == 'type':
                    chat_info['type'] = value
                elif prefix == 'id':
                    chat_info['id'] = value
                    break  # We have what we need
                    
        return chat_info
        
    def create_batch(self, messages: List[Dict], chat_info: Dict, batch_num: int) -> Dict:
        """Create a batch suitable for n8n processing."""
        return {
            'batch_id': f"{chat_info['id']}_{batch_num}",
            'chat_info': chat_info,
            'messages': messages,
            'message_count': len(messages),
            'created_at': datetime.now().isoformat()
        }
        
    def process_file(self, input_path: str, output_dir: str):
        """Process a single Telegram export file."""
        # Extract chat info
        chat_info = self.extract_chat_info(input_path)
        print(f"Processing chat: {chat_info['name']} (type: {chat_info['type']})")
        
        # Create output directory
        output_path = Path(output_dir)
        output_path.mkdir(parents=True, exist_ok=True)
        
        # Process messages in batches
        current_batch = []
        batch_num = 0
        
        # Count total messages first (for progress bar)
        print("Counting messages...")
        total_count = sum(1 for _ in self.stream_messages(input_path))
        
        # Process with progress bar
        with tqdm(total=total_count, desc="Processing messages") as pbar:
            for message in self.stream_messages(input_path):
                # Add chat context to each message
                message['chat_id'] = chat_info['id']
                message['chat_name'] = chat_info['name']
                message['chat_type'] = chat_info['type']
                
                current_batch.append(message)
                pbar.update(1)
                
                # Write batch when size reached
                if len(current_batch) >= self.batch_size:
                    self._write_batch(current_batch, chat_info, batch_num, output_path)
                    batch_num += 1
                    current_batch = []
                    
            # Write final batch
            if current_batch:
                self._write_batch(current_batch, chat_info, batch_num, output_path)
                batch_num += 1
                
        self.total_messages += total_count
        self.total_batches += batch_num
        
        print(f"✓ Processed {total_count} messages into {batch_num} batches")
        
    def _write_batch(self, messages: List[Dict], chat_info: Dict, batch_num: int, output_path: Path):
        """Write a batch to disk."""
        batch = self.create_batch(messages, chat_info, batch_num)
        
        # Create filename with chat name (sanitized)
        safe_name = "".join(c for c in chat_info['name'] if c.isalnum() or c in (' ', '-', '_')).rstrip()
        safe_name = safe_name.replace(' ', '_')[:50]  # Limit length
        
        filename = f"{safe_name}_batch_{batch_num:04d}.json"
        filepath = output_path / filename
        
        with open(filepath, 'w', encoding='utf-8') as f:
            json.dump(batch, f, ensure_ascii=False, indent=2)
            
    def process_directory(self, input_dir: str, output_dir: str):
        """Process all JSON files in a directory."""
        input_path = Path(input_dir)
        json_files = list(input_path.glob('*.json'))
        
        print(f"Found {len(json_files)} JSON files to process")
        
        for file_path in json_files:
            try:
                self.process_file(str(file_path), output_dir)
            except Exception as e:
                print(f"❌ Error processing {file_path}: {e}")
                continue
                
        print(f"\n✅ Total processed: {self.total_messages} messages in {self.total_batches} batches")

def main():
    parser = argparse.ArgumentParser(description='Pre-process Telegram exports for n8n')
    parser.add_argument('--input', required=True, help='Input file or directory')
    parser.add_argument('--output', required=True, help='Output directory for batches')
    parser.add_argument('--batch-size', type=int, default=1000, help='Messages per batch (default: 1000)')
    
    args = parser.parse_args()
    
    processor = TelegramPreprocessor(batch_size=args.batch_size)
    
    input_path = Path(args.input)
    if input_path.is_file():
        processor.process_file(args.input, args.output)
    elif input_path.is_dir():
        processor.process_directory(args.input, args.output)
    else:
        print(f"❌ Error: {args.input} is not a valid file or directory")
        return 1
        
    return 0

if __name__ == '__main__':
    exit(main())