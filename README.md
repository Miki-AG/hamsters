# 🐹 Hamster

**A native Mac GUI for AI workers, packed into one single shell script.**

No installer, server or third-party libraries. Open `main.colony/hamster-founder/` and double-click [`hamster.command`](main.colony/hamster-founder/hamster.command) to open the native interface, configure a worker, and start processing files.

Give it an inbox, an outbox, and a prompt. Drop a file into the inbox. Hamster runs your AI CLI and puts the results in the outbox.

Hamsters are composable. Connect one worker's outbox to another's inbox to chain tasks.

Requires an installed, authenticated Gemini, Claude, or Codex CLI. Hamster adds no extra dependencies.

| A single worker                                                                                    | A colony                                                            |
| -------------------------------------------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| ![Hamster's native window with inbox, worker controls, and outbox](docs/images/hamster-worker.png) | ![Colony managing two workers in a colony](docs/images/hamster-colony.png) |

## How a script becomes a GUI

The Bash launcher runs macOS's built-in JavaScript for Automation through `osascript`. That JavaScript calls Cocoa to create native windows and controls. The interface, settings, folder monitoring, and worker logic all live in the same `.command` file.

There is no build step or separate app bundle. The source file is the file you run. It is easy to inspect and modify. Changes like, for example, adding support for multiple outboxes are trivial.

No rebuild or installer needed, just relaunch the script.

The optional [`colony.command`](main.colony/colony.command) provides a separate native window for managing the workers in its folder. Each Hamster runs on its own without it.

---

## How It Works

1. **Double-click `hamster.command`**: A native Mac window opens with worker controls and settings.
2. **Hit `Start Hamster`**: The Hamster starts watching its inbox.
3. **Drop files in `input/`**: Add files your chosen AI CLI can process, such as PDFs, code snippets, notes, or images.
4. **Collect results in `output/`**: The Hamster processes files one by one and removes each input after it delivers the results successfully.

The default folders are `./input` and `./output` inside the Hamster folder. The UI labels them Inbox and Outbox, and both can be changed with the folder selectors.

While processing, the window shows an animated indicator, the current filename, elapsed time, and log size. The agent's standard output and error output go to `.hamster/last_run.log`, which is replaced when the next task starts.

The agent writes to a temporary output folder, and Hamster delivers those files to the configured outbox. For a failed run, it adds a timestamped `.error` suffix to the output filenames. If the agent produces no output, Hamster writes an error file instead. After delivery, it clears the temporary folder and returns failed inputs to the inbox. If delivery itself fails, files remain in `.hamster/work/` for recovery.
Files ending in `.error` are ignored by workers and excluded from the normal inbox and outbox counts; the outbox shows their total separately in red.

---

## How Authentication and credentials work

Hamsters **never ask for or store API keys**. Instead, they piggyback directly on the command-line tools you already use on your Mac:

- **Google Gemini (`agy` / `gemini`)**: Uses your active login from `agy auth login` or the Antigravity desktop app (or `GEMINI_API_KEY` from your shell).
- **Anthropic Claude (`claude`)**: Uses your active session from `claude login` (Claude Code CLI) or `ANTHROPIC_API_KEY`.
- **OpenAI Codex (`codex`)**: Uses your local Codex configuration or `OPENAI_API_KEY`.

If a tool works when you type its command in your terminal, it works instantly inside Hamster. No secret keys are ever saved to the Hamster script or its configuration files.

---

## Managing your colony: `colony.command`

When you have multiple Hamsters running and don't want floating windows cluttering your screen, double-click **`colony.command`**.

It provides controls for all your workers in one window:

- **Background processing**: Hamsters keep processing their queues without their windows staying open.
- **Fleet controls**: Click **`Start All`** or **`Stop All`** to pause or resume processing across all workers in one click.
- **Per-Hamster toggles**: Hit **`Start`** or **`Stop`** on any individual card to control that specific worker.
- **Open a window**: Click **`Window`** on any card to bring up its full configuration screen whenever you want to inspect logs or adjust prompts.
- **Instant breeding**: Click **`Breed`** to spawn a new Hamster into your colony immediately.

## Multiple colonies

Each folder is a colony. Its `colony.command` lists only the Hamster folders inside it, and **Start All** and **Stop All** apply only to those workers. The window title shows the colony folder name.

Click **Breed Colony** to create and open a new colony beside the current folder. The new `colony-<id>.colony/` folder contains `colony.command` and a single `hamster-<id>/hamster.command`, whose folder name matches its fresh worker ID. That worker starts stopped with default settings and separate working folders. Use **Breed** inside the new colony to add more workers. Both breeding actions copy the instructions, tools, and skills bundle into the new Hamster.

To duplicate a colony with all its worker folders:

1. Open the original `colony.command` once to register its workers, then quit the colony and its workers.
2. Duplicate the entire colony folder in Finder and rename the copy, for example `research.colony/`.
3. Keep the original in place and open `research.colony/colony.command` to register the copied workers.

When the recorded original script still exists, a copied worker gets a new ID and resets its copied runtime data and settings. It starts stopped with the default folders. Finder also copies `instructions/`, `skills/`, `tools/`, and **all files in `input/` and `output/`**. Remove any copied queue files you do not want before starting the workers. Each worker uses your existing AI CLI authentication.

**Breed** creates a new worker folder in the same colony with empty input and output folders. To move an existing worker or rename a colony, quit its workers first, move or rename the folder, and reopen Colony. When the recorded original script no longer exists, the worker keeps its ID and runtime data. Check saved folder paths before starting it, since configuration can contain absolute paths to the old location or external folders.

## Files in a Hamster

The repository includes `main.colony/colony.command` and the original worker in `main.colony/hamster-founder/`. Each worker stores its assets and runtime files together:

```text
hamster-founder/          # Bred workers use hamster-<id>/
    hamster.command
    input/
    output/
    instructions/
        prompt.md
    skills/
    tools/
    .hamster/            # Created at runtime
        config.json
        location.txt
        state.txt
        app.pid          # Present while the worker runs
        last_run.log
        work/
            claim/
            output_staging/
```

`input/`, `output/`, `skills/`, `tools/`, and `instructions/` are local worker data. Add your own files to these folders. The repository ignores their contents, so personal prompts, instructions, skills, and tools stay out of commits.

The repository's `.gitignore` excludes:

- Additional worker folders inside `main.colony/`.
- Sibling colony folders named `*.colony/`, except `main.colony/` itself.
- Runtime data under `.hamster/` and working files under `input/` and `output/`.
- Local contents of the founder's `skills/` and `tools/`, except their `.gitkeep` placeholders.
- All files inside every worker's `instructions/` folder.

Hamster concatenates the non-hidden files in `instructions/` in filename order and passes the result to the agent. Use separate files when you want to organize a prompt into reusable sections. The Settings text area shows the concatenated text and **Save Configuration** writes it to `instructions/prompt.md`. Ignore rules do not hide files that are already tracked.

For development, run `node tests/colonies.cjs` on macOS to check registration, copying, moving, and colony controls using temporary files and the native automation runtime. Node is only needed for this test script.

---

## Workflows built from folders

Set one Hamster's **Outbox** and the next Hamster's **Inbox** to the same folder. Every handoff below is a file in that folder. Workers process one input item at a time, so each handoff must include all the context the next worker needs. Use a unique filename for each job.

These are workflows you can configure through prompts and folder settings. Agents can use the tools available through your AI CLI, including Git, web lookup, SSH, and local scripts. Configure the required tools, credentials, and file access for each worker. Hamster itself adds no tool dependencies.

### 1. Meeting follow-up

Put a meeting transcript in the first inbox. The summarizer writes one Markdown file containing the meeting context, decisions, action items, owners, and deadlines. The email drafter turns that file into a follow-up email for you to review and send.

```mermaid
flowchart LR
    Inbox["Inbox<br/>Meeting transcript"] --> Summarizer(["Summarizer"])
    Summarizer --> Handoff["Outbox / Inbox<br/>Meeting summary"]
    Handoff --> Drafter(["Email drafter"])
    Drafter --> Outbox["Outbox<br/>Follow-up email draft"]
```

### 2. Release notes

Drop in a request file specifying the repository, commit range, and intended audience. The Git researcher uses Git to inspect that range and writes a change report with the request details and supporting commit references. The release-note writer uses the report to draft release notes for review.

```mermaid
flowchart LR
    Inbox["Inbox<br/>Release request"] --> Researcher(["Git researcher"])
    Researcher --> Handoff["Outbox / Inbox<br/>Change report"]
    Handoff --> Writer(["Release-note writer"])
    Writer --> Outbox["Outbox<br/>Release notes draft"]
```

Give the researcher access to the repository. Use a separate checkout for each worker that changes repository files.

### 3. Outbound sales email drafts

Each prospect file names a company, its website, and your product or offer. The company researcher checks public webpages to identify a relevant contact, their role, and a concrete reason the company could benefit. It writes one research file containing the offer, findings, source URLs, and any uncertainty about contact details.

The email drafter uses that file to write a personalized subject line and email for your review. Instruct it to flag missing contact information rather than invent an address. The output is a draft; sending is a separate step.

```mermaid
flowchart LR
    Inbox["Inbox<br/>Company and offer"] --> Researcher(["Company researcher"])
    Researcher --> Handoff["Outbox / Inbox<br/>Contact and company research"]
    Handoff --> Drafter(["Email drafter"])
    Drafter --> Outbox["Outbox<br/>Sales email draft"]
```

### 4. Automated Obsidian indexing

Drop copies of PDFs, notes, saved webpages, images, or recordings into the first inbox. The content normalizer uses the extraction, OCR, or transcription tools you have configured to produce one self-contained Markdown file per input, including source details. Keep originals elsewhere if you need to retain them: Hamster consumes successfully processed inputs.

The vault indexer reads each Markdown file, creates or updates a note in your configured Obsidian vault, adds tags and links, and updates an index note. It uses file tools to make those vault edits, then writes a receipt to its outbox identifying the files changed. Configure it to recognize previously indexed sources so retries update existing notes.

```mermaid
flowchart LR
    Inbox["Inbox<br/>Mixed source files"] --> Normalizer(["Content normalizer"])
    Normalizer --> Handoff["Outbox / Inbox<br/>Normalized Markdown"]
    Handoff --> Indexer(["Vault indexer"])
    Indexer --> Outbox["Outbox<br/>Indexing receipt"]
```

Give the indexer access to the vault and use one indexer per vault to avoid competing edits to the index. The vault is a separate destination edited by that agent; the receipt is its output for the Hamster workflow.

Each workflow has a dedicated inbox per stage. Workers sharing an inbox compete for files; sharing does not broadcast a file to every worker or select a specialist automatically.

---

## Breeding: instant duplication

Need another worker for a different job? Click **Breed Hamster** in the worker window or **Breed** in the colony window.

A new `hamster-<id>/` folder appears in the same colony with a fresh ID, its own script, and empty `input/` and `output/` folders. Breeding copies `instructions/`, `tools/`, and `skills/` from the source worker. Review the new worker's settings before starting it.

---

## Customizing your Hamster

Open the **Settings** tab to configure a worker:

- **Hamster Home**: The base directory for relative input and output paths. It defaults to the folder containing `hamster.command`. Changing it does not move the script or its assets.
- **Input & Output**: Choose the folders it watches and delivers results to. The defaults are `./input` and `./output`.
- **AI Backend**: Choose between **Gemini (`agy`)**, **Claude (`claude`)**, or **Codex (`codex`)**.
- **Instructions**: Hamster concatenates the non-hidden files in `instructions/` in filename order when it opens. The Settings text area shows that combined text. Save settings to write the text to `instructions/prompt.md`, or edit the files directly and relaunch the worker.
- **Tools & Skills**: Use the worker's local `tools/` and `skills/` folders by default, or select other folders containing scripts and skill guides for the agent.

---

## Requirements

- macOS 12.0+
- Any one (or more) of the following CLI tools installed:
  - **Google Gemini / Antigravity CLI** (`agy` or `gemini`)
  - **Anthropic Claude Code CLI** (`claude`)
  - **OpenAI Codex CLI** (`codex`)
