# Project Agent Rules & `pstack` Engineering Rigor

This repository adopts **pstack** principles and engineering workflows adapted natively for Google Antigravity.

---

## 1. Critical Rules & Guardrails
- **Gerrit Workflow (MANDATORY)**: We are working on Gerrit. You must **NEVER commit or push code** to the repository. Only stage changes or leave them in the working directory as instructed.
- **Direct Answers**: When asked a question, respond directly and concisely. Do not write or modify code unless explicitly asked.
- **Evidence-Based Engineering**: Never claim a bug is fixed or a feature works without running verification commands and observing real runtime output.

---

## 2. Poteto Mode & Core Principles
When working in `poteto-mode` or on any non-trivial engineering task:
1. **Start with a Checklist**: Ground multi-step tasks with a clear checklist of verifiable steps.
2. **Laziness Protocol**: Prefer the simplest change that solves the problem. Delete dead code and unnecessary layers.
3. **Model the Domain**: Ground logic in precise data shapes, types, and state machines rather than ad-hoc branching.
4. **Boundary Discipline & Type Safety**: Validate external input at boundaries; make illegal states unrepresentable.
5. **Fix Root Causes**: Debug by reproducing first, isolating the failure mechanism, and fixing the cause rather than symptoms.
6. **No Clutter / Unslop**: Keep comments minimal (only explaining non-obvious *why*), write clean declarative sentences without AI boilerplate.

---

## 3. Subagent Orchestration
Subagents can be invoked using `invoke_subagent` or defined via `define_subagent`.

- **`poteto-agent`**: General-purpose delegate adhering to `poteto-mode` guidelines and principles. Default model: `inherit` or `pro`.
- **`comment-sicko`**: Specialized review subagent that audits diffs and flags unnecessary comments, obsolete suppressions, and complex workaround prose for removal.
- **Model Tiers**:
  - `flash`: Fast mechanical edits, parallel sweeps, test runners, log analyzers.
  - `pro`: Complex architectural design, deep debugging, adversarial reviews (`interrogate`), multi-model synthesis.
  - `inherit`: Inherits the active conversation model.

---

## 4. Skills & Playbooks Reference
All skills and playbooks are available in [`.agents/skills/`](file:///.agents/skills) and can be invoked on demand:
- **`poteto-mode`**: Master coordinator routing to 22 playbooks (`bug-fix`, `feature`, `investigation`, `perf-issue`, `refactoring`, `prototype`, etc.).
- **`architect`**, **`arena`**, **`swarm`**, **`interrogate`**: Multi-agent exploration, competitive design bakeoffs, and adversarial review.
- **`how`** / **`why`**: Lineage and runtime forensics.
- **`tdd`** / **`unslop`** / **`technical-writing`** / **`no-comments`**: Craftsmanship and code quality filters.
- **`figure-it-out`** / **`show-me-your-work`**: Autonomous runs with auditable decision logs.
