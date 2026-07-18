# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## Память Claude Code (auto-memory)

Директория памяти этого проекта — `~/.claude/projects/-home-amar-Amar73-rclone/memory/` —
является клоном приватного репозитория `Amar73/claude-memory-rclone` и синхронизируется
между машинами вручную через git:

- **В начале сессии** (если на этой машине давно не работал): сделай `git pull` в этой директории.
- **В конце сессии, если память менялась**: `git add -A && git commit && git push` там же.

Подробности — в `README.md` внутри самой директории памяти.
