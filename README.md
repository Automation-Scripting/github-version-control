# rel — Release & Milestone Workflow for GitHub Projects

`rel` is a **zsh-based release engineering module** that implements a structured workflow using **GitHub Projects (v2)** for planning and **GitHub Releases** for immutable delivery history.

The design is inspired by mature ecosystems such as:

- Linux kernel versioning
- Python (PEPs and release lines)
- Serious RFC-driven projects

The core idea is to **separate planning from delivery**, while keeping both tightly linked and auditable.

---

## Core Concepts

The workflow is built around **two distinct version layers**:

1. **Development lines (GitHub Projects)**
2. **Releases (Git tags + GitHub Releases)**

They intentionally do **not** have the same lifecycle.

---

## 1. Development Lines (GitHub Projects)

Open GitHub Projects represent **active development lines**, not released versions.

### Naming convention
vX.Y.x

Examples:
- `v0.0.x` — initial development line
- `v0.1.x` — next minor development line
- `v1.0.x` — major maintenance line

### Properties

- Always **open**
- Contain issues/items under active work
- Represent *what is still evolving*
- Never represent a finalized release

This is equivalent to:
- Linux `stable` branches
- Python feature cycles
- RFC draft series

---

## 2. Releases (Git Tags + GitHub Releases)

Releases are **immutable delivery points**.

### Patch releases

Triggered via:

