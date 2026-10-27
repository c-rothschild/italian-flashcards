#!/bin/bash
# Double-click in Finder to start the flashcard app (opens your browser).
cd "$(dirname "$0")" && exec python3 server.py
