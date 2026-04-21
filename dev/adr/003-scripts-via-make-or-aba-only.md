# ADR-003: Scripts called only via Make or aba CLI

## Status
Accepted

## Context
Scripts under scripts/ depend on Make for: correct CWD (set by make -C),
dependency tracking (prerequisites run first), and marker management
(.available, .init created/removed by Make rules). Calling scripts directly
bypasses all of this.

## Decision
Scripts under scripts/ must only be called via Make targets or the aba CLI.
Never directly. A runtime guardrail (env var check) is planned to enforce
this (see backlog).

Makefiles own all marker files (.init, .available, .unavailable, etc.).
Scripts must not touch/rm these markers -- that is the Makefile's job.

## Consequences
- Clear separation: Makefiles handle lifecycle state, scripts handle logic
- Every workflow remains invocable as `make -C <dir> <target>` directly
- Essential logic must not live only in aba.sh (Make must keep working)
- Testing requires going through aba/make, not calling scripts directly
