#!/bin/bash
# ==============================================================================
# 🐹 HAMSTER - Single-File macOS Autonomous Worker Prototype
# ==============================================================================
# Hard Constraints:
# - Entire app contained in this single .command file.
# - No external packages or compilers; uses macOS native zsh/bash, JXA & AppKit.
# - Each Hamster keeps its script, prompt, folders, tools, skills, and runtime state together.
# - Simplified, elegant 2-Tab Layout without heavy nested frames.
# - Tab 1: 🐹 Hamster Wheel (3 clean columns with all texts perfectly centered)
# - Tab 2: ⚙️ Settings (Clean configuration layout)
# - Safe claiming, processing, and atomic output finalization.
# - Native Cocoa event loop (app.run) for instantaneous UI responsiveness.
# - Full Dock, Cmd+Tab, and Menu Bar integration.
# ==============================================================================

# Ensure common CLI paths are available even when launched from Finder
export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$HOME/.gemini/bin:$HOME/.codex/bin:$HOME/.claude/bin:$HOME/bin:$PATH"

# Persistent Unique Hamster Identity placeholder (auto-populated on first run or clone)
HAMSTER_ID="HAMSTER_ID_PLACEHOLDER"

# Canonical path to this script and its containing Hamster folder
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"
WORKER_DIR="$(cd "$(dirname "$SCRIPT_PATH")" && pwd)"

# Base storage directory
BASE_STORAGE="$HOME/Library/Application Support/Hamsters"

# ------------------------------------------------------------------------------
# 1. Identity Initialization & Self-Healing Clone Detection
# ------------------------------------------------------------------------------
if [ "$HAMSTER_ID" = "HAMSTER_ID_PLACEHOLDER" ] || [ -z "$HAMSTER_ID" ]; then
    NEW_ID="hamster-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
    sed -i '' "s/^HAMSTER_ID=.*/HAMSTER_ID=\"$NEW_ID\"/" "$SCRIPT_PATH" || exit 1
    HAMSTER_ID="$NEW_ID"
fi

RUNTIME_DIR="$WORKER_DIR/.hamster"
LEGACY_DIR="$BASE_STORAGE/$HAMSTER_ID"
LOC_FILE="$RUNTIME_DIR/location.txt"
PID_FILE="$RUNTIME_DIR/app.pid"

# A missing previous location means the script moved; an existing one means it was copied.
REGISTERED_PATH=""
if [ -f "$LOC_FILE" ]; then
    REGISTERED_PATH=$(cat "$LOC_FILE" 2>/dev/null)
elif [ -f "$LEGACY_DIR/location.txt" ]; then
    REGISTERED_PATH=$(cat "$LEGACY_DIR/location.txt" 2>/dev/null)
fi
if [ -n "$REGISTERED_PATH" ]; then
    if [ "$REGISTERED_PATH" != "$SCRIPT_PATH" ] && [ -f "$REGISTERED_PATH" ]; then
        # Spawn a new independent ID for this clone
        CLONE_ID="hamster-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
        rm -rf "$RUNTIME_DIR"
        sed -i '' "s/^HAMSTER_ID=.*/HAMSTER_ID=\"$CLONE_ID\"/" "$SCRIPT_PATH" || exit 1
        HAMSTER_ID="$CLONE_ID"
        RUNTIME_DIR="$WORKER_DIR/.hamster"
        LEGACY_DIR="$BASE_STORAGE/$HAMSTER_ID"
        LOC_FILE="$RUNTIME_DIR/location.txt"
        PID_FILE="$RUNTIME_DIR/app.pid"
    fi
fi

if [ ! -d "$RUNTIME_DIR" ] && [ -d "$LEGACY_DIR" ] && [ ! -f "$REGISTERED_PATH" ]; then
    mv "$LEGACY_DIR" "$RUNTIME_DIR" || exit 1
fi
mkdir -p "$RUNTIME_DIR/work/claim" "$RUNTIME_DIR/work/output_staging" || exit 1
printf '%s\n' "$SCRIPT_PATH" > "$LOC_FILE" || exit 1

if [ "$1" = "--register" ]; then
    exit 0
fi

# ------------------------------------------------------------------------------
# Auto-Dismiss Terminal Window if launched from Finder / Terminal
# ------------------------------------------------------------------------------
if [ "$1" != "--gui-worker" ]; then
    nohup "$SCRIPT_PATH" --gui-worker "$@" >/dev/null 2>&1 &
    osascript -e '
    tell application "Terminal"
        if (count of windows) > 0 then
            close front window
        end if
    end tell' 2>/dev/null &
    exit 0
fi

# ------------------------------------------------------------------------------
# 2. Single-Instance Enforcement per Hamster
# ------------------------------------------------------------------------------
if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        if [[ "$*" == *"--headless"* ]] || [[ "$*" == *"--start"* ]]; then
            echo "RUNNING" > "$RUNTIME_DIR/state.txt"
            exit 0
        fi
        if [[ "$*" == *"--stop"* ]]; then
            echo "STOPPED" > "$RUNTIME_DIR/state.txt"
            exit 0
        fi
        # Bring existing instance to the front and reopen window
        osascript -e "
        tell application \"System Events\"
            set pList to (every process whose unix id is $EXISTING_PID)
            if (count of pList) > 0 then
                set frontmost of (item 1 of pList) to true
            end if
        end tell
        " 2>/dev/null || true
        open "$SCRIPT_PATH" 2>/dev/null || true
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# 3. Clean Launch Hand-Off (Direct process replacement with JXA)
# ------------------------------------------------------------------------------
exec /usr/bin/osascript -l JavaScript - "$HAMSTER_ID" "$RUNTIME_DIR" "$SCRIPT_PATH" "$REGISTERED_PATH" "$@" << 'EOF'
function run(argv) {
    ObjC.import("Cocoa");

    const hamsterId = argv[0];
    const hamsterDir = argv[1];
    const scriptPath = argv[2];
    const previousScriptPath = (argv[3] && argv[3].startsWith("/")) ? argv[3] : scriptPath;
    const workerDir = scriptPath.substring(0, scriptPath.lastIndexOf("/"));
    const configFile = hamsterDir + "/config.json";
    const logFile = hamsterDir + "/last_run.log";
    const pidFile = hamsterDir + "/app.pid";
    const stateFile = hamsterDir + "/state.txt";
    const instructionsDir = workerDir + "/instructions";
    const promptFile = instructionsDir + "/prompt.md";
    const toolsDir = workerDir + "/tools";
    const skillsDir = workerDir + "/skills";
    const defaultPrompt = "Read the input file, process it according to the requested transformation, and write the resulting output file to the specified output folder.";

    const fm = $.NSFileManager.defaultManager;
    const userHome = "/Users/" + $.NSUserName().js;

    function getWorkerState() {
        if (!fm.fileExistsAtPath(stateFile)) return false;
        try {
            const str = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(stateFile, $.NSUTF8StringEncoding, $())).trim();
            return (str === "RUNNING");
        } catch(e) {
            return false;
        }
    }

    function setWorkerState(running) {
        const str = running ? "RUNNING" : "STOPPED";
        const ns = $.NSString.stringWithString(str);
        ns.writeToFileAtomicallyEncodingError(stateFile, true, $.NSUTF8StringEncoding, $());
    }

    // Bridge-safe filesystem helpers
    function makeDir(path) {
        if (!path) return;
        if (!fm.fileExistsAtPath(path)) {
            fm.createDirectoryAtPathWithIntermediateDirectoriesAttributesError(path, true, $(), $());
        }
    }

    function listDir(path) {
        if (!path || !fm.fileExistsAtPath(path)) return [];
        const contents = fm.contentsOfDirectoryAtPathError(path, $());
        if (contents && !contents.isNil()) {
            const arr = [];
            const count = contents.count;
            for (let i = 0; i < count; i++) {
                arr.push(contents.objectAtIndex(i).js);
            }
            return arr;
        }
        return [];
    }

    function readText(path) {
        if (!path || !fm.fileExistsAtPath(path)) return "";
        try {
            return ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(path, $.NSUTF8StringEncoding, $()));
        } catch (e) {
            return "";
        }
    }

    function readInstructions() {
        const files = listDir(instructionsDir)
            .filter(name => !name.startsWith(".") && !name.endsWith(".tmp"))
            .sort();
        return files.map(name => readText(instructionsDir + "/" + name).trim())
            .filter(text => text.length > 0)
            .join("\n\n");
    }

    function removePath(path) {
        if (path && fm.fileExistsAtPath(path)) {
            fm.removeItemAtPathError(path, $());
        }
    }

    function movePath(src, dest) {
        if (fm.fileExistsAtPath(dest)) {
            fm.removeItemAtPathError(dest, $());
        }
        return fm.moveItemAtPathToPathError(src, dest, $());
    }

    function restoreClaim(claimPath, originalPath) {
        if (!fm.fileExistsAtPath(originalPath)) {
            return movePath(claimPath, originalPath);
        }
        let recoveredPath = originalPath + ".hamster-recovered";
        let suffix = 2;
        while (fm.fileExistsAtPath(recoveredPath)) {
            recoveredPath = originalPath + ".hamster-recovered-" + suffix;
            suffix++;
        }
        return movePath(claimPath, recoveredPath);
    }

    function getAttrs(path) {
        if (!path || !fm.fileExistsAtPath(path)) return null;
        return fm.attributesOfItemAtPathError(path, $());
    }

    function writeText(path, text) {
        const ns = $.NSString.stringWithString(text || "");
        ns.writeToFileAtomicallyEncodingError(path, true, $.NSUTF8StringEncoding, $());
    }

    function appendLog(text) {
        let existing = "";
        if (fm.fileExistsAtPath(logFile)) {
            try {
                existing = ObjC.unwrap($.NSString.stringWithContentsOfFileEncodingError(logFile, $.NSUTF8StringEncoding, $()));
            } catch (e) {}
        }
        writeText(logFile, existing + text);
    }

    function formatDuration(totalSeconds) {
        const seconds = Math.max(0, Math.floor(totalSeconds));
        const minutes = Math.floor(seconds / 60);
        const remainder = seconds % 60;
        return minutes > 0 ? minutes + "m " + (remainder < 10 ? "0" : "") + remainder + "s" : seconds + "s";
    }

    function formatBytes(bytes) {
        if (bytes < 1024) return bytes + " B";
        if (bytes < 1024 * 1024) return (bytes / 1024).toFixed(1) + " KB";
        return (bytes / (1024 * 1024)).toFixed(1) + " MB";
    }

    function isErrorFile(filename) {
        return String(filename).toLowerCase().endsWith(".error");
    }

    function errorOutputPath(outDir, filename) {
        const stamp = new Date().toISOString().replace(/[-:]/g, "").replace(/\.\d{3}Z$/, "Z");
        let candidate = outDir + "/" + filename + "." + stamp + ".error";
        let suffix = 2;
        while (fm.fileExistsAtPath(candidate)) {
            candidate = outDir + "/" + filename + "." + stamp + "-" + suffix + ".error";
            suffix++;
        }
        return candidate;
    }

    function shellQuote(value) {
        return "'" + String(value).replace(/'/g, "'\\''") + "'";
    }

    function toDisplayPath(fullPath, homePath) {
        if (!fullPath) return "";
        const cleanFull = fullPath.replace(/\/+$/, "");
        const cleanHome = (homePath || "").replace(/\/+$/, "");
        if (cleanHome && cleanFull.startsWith(cleanHome + "/")) {
            return "./" + cleanFull.substring(cleanHome.length + 1);
        }
        if (cleanHome && cleanFull === cleanHome) {
            return "./";
        }
        return fullPath;
    }

    function fromDisplayPath(displayPath, homePath) {
        if (!displayPath) return "";
        const trimmed = displayPath.trim();
        if (trimmed.startsWith("/")) {
            return trimmed;
        }
        if (trimmed.startsWith("~")) {
            return trimmed.replace(/^~/, userHome);
        }
        const cleanHome = (homePath || (userHome + "/Hamsters/Hamster_" + hamsterId)).replace(/\/+$/, "");
        if (trimmed === "." || trimmed === "./" || trimmed === "") {
            return cleanHome;
        }
        return cleanHome + "/" + trimmed;
    }

    // Record active PID for single-instance tracking
    const currentPid = $.NSProcessInfo.processInfo.processIdentifier;
    const pidStr = $.NSString.stringWithString("" + currentPid);
    pidStr.writeToFileAtomicallyEncodingError(pidFile, true, $.NSUTF8StringEncoding, $());

    // Initial default naming & directories
    const defaultName = "Hamster " + hamsterId.replace("hamster-", "");
    const defaultHome = workerDir;
    const defaultInbox = workerDir + "/input";
    const defaultOutbox = workerDir + "/output";

    let config = {
        name: defaultName,
        homeFolder: defaultHome,
        inputFolder: defaultInbox,
        outputFolder: defaultOutbox,
        agent: "gemini",
        instructions: defaultPrompt,
        tools: [toolsDir],
        skills: [skillsDir]
    };

    if (fm.fileExistsAtPath(configFile)) {
        try {
            const data = $.NSString.stringWithContentsOfFileEncodingError(configFile, $.NSUTF8StringEncoding, $());
            const parsed = JSON.parse(ObjC.unwrap(data));
            config = Object.assign(config, parsed);
        } catch (e) {}
    }

    function remapMovedPath(value, oldRoot, newRoot) {
        if (!value || !oldRoot || oldRoot === newRoot) return value;
        if (value === oldRoot) return newRoot;
        if (value.startsWith(oldRoot + "/")) return newRoot + value.substring(oldRoot.length);
        return value;
    }

    const previousWorkerDir = previousScriptPath.substring(0, previousScriptPath.lastIndexOf("/"));
    if (previousWorkerDir && previousWorkerDir !== workerDir) {
        config.homeFolder = remapMovedPath(config.homeFolder, previousWorkerDir, workerDir);
        config.inputFolder = remapMovedPath(config.inputFolder, previousWorkerDir, workerDir);
        config.outputFolder = remapMovedPath(config.outputFolder, previousWorkerDir, workerDir);
        config.tools = (config.tools || []).map(path => remapMovedPath(path, previousWorkerDir, workerDir));
        config.skills = (config.skills || []).map(path => remapMovedPath(path, previousWorkerDir, workerDir));
    }

    const defaultDisplayName = "Hamster " + hamsterId.replace("hamster-", "");
    if (!config.displayName) config.displayName = config.name || defaultDisplayName;
    if (!config.homeFolder) config.homeFolder = defaultHome;
    if (!config.inputFolder) config.inputFolder = defaultInbox;
    if (!config.outputFolder) config.outputFolder = defaultOutbox;
    config.homeFolder = fromDisplayPath(config.homeFolder, workerDir);
    config.inputFolder = fromDisplayPath(config.inputFolder, config.homeFolder);
    config.outputFolder = fromDisplayPath(config.outputFolder, config.homeFolder);
    if (!config.instructions) config.instructions = defaultPrompt;
    if (!Array.isArray(config.tools)) config.tools = [toolsDir];
    if (!Array.isArray(config.skills)) config.skills = [skillsDir];
    config.tools = config.tools.map(path => fromDisplayPath(path, workerDir));
    config.skills = config.skills.map(path => fromDisplayPath(path, workerDir));

    makeDir(workerDir);
    makeDir(instructionsDir);
    makeDir(toolsDir);
    makeDir(skillsDir);
    const instructionText = readInstructions();
    if (instructionText) {
        config.instructions = instructionText;
    } else {
        writeText(promptFile, config.instructions + "\n");
    }

    makeDir(config.homeFolder);
    makeDir(config.inputFolder);
    makeDir(config.outputFolder);

    function recoverClaims() {
        for (let filename of listDir(hamsterDir + "/work/claim")) {
            if (filename.startsWith(".") || filename.endsWith(".tmp")) continue;
            const claimPath = hamsterDir + "/work/claim/" + filename;
            const originalPath = config.inputFolder + "/" + filename;
            restoreClaim(claimPath, originalPath);
        }
    }
    recoverClaims();

    function saveConfig() {
        const jsonStr = JSON.stringify(config, null, 2);
        const nsStr = $.NSString.stringWithString(jsonStr);
        nsStr.writeToFileAtomicallyEncodingError(configFile, true, $.NSUTF8StringEncoding, $());
        makeDir(instructionsDir);
        writeText(promptFile, config.instructions + "\n");
    }

    saveConfig();

    // CLI Detection
    function detectCLI(name) {
        const paths = [
            "/usr/local/bin/" + name,
            "/opt/homebrew/bin/" + name,
            userHome + "/.local/bin/" + name,
            userHome + "/.gemini/bin/" + name,
            userHome + "/.claude/bin/" + name,
            userHome + "/.codex/bin/" + name,
            "/usr/bin/" + name
        ];
        for (let p of paths) {
            if (fm.isExecutableFileAtPath(p)) return p;
        }
        return null;
    }

    const agyPath = detectCLI("agy") || detectCLI("gemini");
    const claudePath = detectCLI("claude");
    const codexPath = detectCLI("codex");

    // App & Window Setup
    const app = $.NSApplication.sharedApplication;
    app.setActivationPolicy($.NSApplicationActivationPolicyRegular);
    app.finishLaunching;

    // Menu Bar Setup
    const menubar = $.NSMenu.alloc.init;

    const appMenuItem = $.NSMenuItem.alloc.init;
    menubar.addItem(appMenuItem);
    const appMenu = $.NSMenu.alloc.init;
    appMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent("Quit Hamster", "terminate:", "q"));
    appMenuItem.setSubmenu(appMenu);

    const editMenuItem = $.NSMenuItem.alloc.init;
    menubar.addItem(editMenuItem);
    const editMenu = $.NSMenu.alloc.initWithTitle("Edit");
    editMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent("Undo", "undo:", "z"));
    editMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent("Redo", "redo:", "Z"));
    editMenu.addItem($.NSMenuItem.separatorItem);
    editMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent("Cut", "cut:", "x"));
    editMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent("Copy", "copy:", "c"));
    editMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent("Paste", "paste:", "v"));
    editMenu.addItem($.NSMenuItem.alloc.initWithTitleActionKeyEquivalent("Select All", "selectAll:", "a"));
    editMenuItem.setSubmenu(editMenu);

    app.setMainMenu(menubar);

    const winWidth = 660;
    const winHeight = 560;
    const winRect = $.NSMakeRect(200, 200, winWidth, winHeight);
    const styleMask = $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable | $.NSWindowStyleMaskMiniaturizable;
    const win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(winRect, styleMask, $.NSBackingStoreBuffered, false);

    win.setTitle("🐹 " + config.displayName + " (" + hamsterId + ")");
    win.setReleasedWhenClosed(false);
    win.center;

    const contentView = win.contentView;

    // Helper UI creators
    function createLabel(text, x, y, w, h, isBold, size, parent, isCenter) {
        const label = $.NSTextField.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
        label.setStringValue(text);
        label.setBezeled(false);
        label.setDrawsBackground(false);
        label.setEditable(false);
        label.setSelectable(false);
        if (isCenter) {
            label.setAlignment($.NSTextAlignmentCenter);
            if (label.cell) label.cell.setAlignment($.NSTextAlignmentCenter);
        }
        if (isBold) {
            label.setFont($.NSFont.boldSystemFontOfSize(size || 13));
        } else if (size) {
            label.setFont($.NSFont.systemFontOfSize(size));
        }
        (parent || contentView).addSubview(label);
        return label;
    }

    function setCenterText(field, text, color) {
        field.setStringValue(text || "");
        field.setAlignment($.NSTextAlignmentCenter);
        if (field.cell) field.cell.setAlignment($.NSTextAlignmentCenter);
        if (color) field.setTextColor(color);
    }

    function setLeftText(field, text, color) {
        field.setStringValue(text || "");
        field.setAlignment($.NSTextAlignmentLeft);
        if (field.cell) field.cell.setAlignment($.NSTextAlignmentLeft);
        if (color) field.setTextColor(color);
    }

    function createTextField(text, x, y, w, h, parent) {
        const tf = $.NSTextField.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
        tf.setStringValue(text || "");
        (parent || contentView).addSubview(tf);
        return tf;
    }

    function createButton(title, x, y, w, h, parent) {
        const btn = $.NSButton.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
        btn.setTitle(title);
        btn.setBezelStyle($.NSBezelStyleRounded);
        (parent || contentView).addSubview(btn);
        return btn;
    }

    // Top Header Banner
    const headerTitleLabel = createLabel("🐹 " + config.displayName, 20, winHeight - 36, 350, 22, true, 16, contentView, false);
    createLabel("ID: " + hamsterId, winWidth - 220, winHeight - 34, 200, 18, false, 11, contentView, false);

    // Tab View
    const tabView = $.NSTabView.alloc.initWithFrame($.NSMakeRect(15, 10, winWidth - 30, winHeight - 50));
    contentView.addSubview(tabView);

    // =========================================================================
    // TAB 1: 🐹 Hamster Wheel (Clean Row-Based Layout)
    // =========================================================================
    const tab1 = $.NSTabViewItem.alloc.init;
    tab1.label = "🐹 Hamster Wheel";
    const wheelView = $.NSView.alloc.initWithFrame(tabView.bounds);
    tab1.view = wheelView;
    tabView.addTabViewItem(tab1);

    const rowW = 595;
    const rowX = 15;

    // --- Row 1: Inbox Row (Top) ---
    const inboxBox = $.NSBox.alloc.initWithFrame($.NSMakeRect(rowX, 350, rowW, 95));
    inboxBox.setBoxType($.NSBoxCustom);
    inboxBox.setBorderType($.NSLineBorder);
    inboxBox.setBorderWidth(1.0);
    inboxBox.setBorderColor($.NSColor.separatorColor);
    inboxBox.setCornerRadius(8.0);
    inboxBox.setFillColor($.NSColor.controlBackgroundColor);
    wheelView.addSubview(inboxBox);

    // Big Icon on Left of Large Number
    createLabel("📥", 18, 16, 46, 60, false, 36, inboxBox, false);

    const inputCountLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(68, 12, 115, 68));
    inputCountLabel.setBezeled(false);
    inputCountLabel.setDrawsBackground(false);
    inputCountLabel.setEditable(false);
    inputCountLabel.setSelectable(false);
    inputCountLabel.setFont($.NSFont.boldSystemFontOfSize(48));
    setLeftText(inputCountLabel, "0", $.NSColor.systemBlueColor);
    inboxBox.addSubview(inputCountLabel);

    createLabel("Inbox", 195, 50, 220, 24, true, 16, inboxBox, false);
    const inDesc = createLabel("Files waiting to be processed", 195, 26, 220, 18, false, 12, inboxBox, false);
    inDesc.setTextColor($.NSColor.secondaryLabelColor);

    const btnWheelOpenInput = createButton("📂 Open Inbox", rowW - 155, 30, 135, 34, inboxBox);

    // --- Row 2: Controls & Status (Middle) ---
    const controlsBox = $.NSBox.alloc.initWithFrame($.NSMakeRect(rowX, 230, rowW, 105));
    controlsBox.setBoxType($.NSBoxCustom);
    controlsBox.setBorderType($.NSLineBorder);
    controlsBox.setBorderWidth(1.0);
    controlsBox.setBorderColor($.NSColor.separatorColor);
    controlsBox.setCornerRadius(8.0);
    controlsBox.setFillColor($.NSColor.controlBackgroundColor);
    wheelView.addSubview(controlsBox);

    createLabel("⚙️", 18, 16, 46, 60, false, 36, controlsBox, false);
    const workerStateLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(68, 12, 115, 68));
    workerStateLabel.setBezeled(false);
    workerStateLabel.setDrawsBackground(false);
    workerStateLabel.setEditable(false);
    workerStateLabel.setSelectable(false);
    workerStateLabel.setFont($.NSFont.boldSystemFontOfSize(48));
    setLeftText(workerStateLabel, "0", $.NSColor.secondaryLabelColor);
    controlsBox.addSubview(workerStateLabel);

    const btnStartStop = createButton("▶ Start Hamster", 195, 30, 165, 46, controlsBox);
    btnStartStop.setFont($.NSFont.boldSystemFontOfSize(14));

    const statusLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(195, 8, 220, 16));
    statusLabel.setBezeled(false);
    statusLabel.setDrawsBackground(false);
    statusLabel.setEditable(false);
    statusLabel.setSelectable(false);
    statusLabel.setFont($.NSFont.boldSystemFontOfSize(11));
    setCenterText(statusLabel, "", $.NSColor.secondaryLabelColor);
    controlsBox.addSubview(statusLabel);

    const progressDetailLabel = createLabel("", 15, 84, 400, 16, false, 11, controlsBox, false);
    progressDetailLabel.setTextColor($.NSColor.secondaryLabelColor);

    function setWorkerStateIndicator(working) {
        setLeftText(workerStateLabel, working ? "1" : "0", working ? $.NSColor.systemOrangeColor : $.NSColor.secondaryLabelColor);
    }

    const isAutoStart = argv.some(a => a === "--autostart");
    if (isAutoStart) {
        btnStartStop.setTitle("⏹ Stop Hamster");
    }

    const btnWheelViewLog = createButton("📄 View Last Log", rowW - 165, 55, 145, 30, controlsBox);
    const btnWheelCreateHamster = createButton("✨ Breed Hamster", rowW - 165, 18, 145, 30, controlsBox);

    // --- Row 3: Outbox Row (Bottom) ---
    const outboxBox = $.NSBox.alloc.initWithFrame($.NSMakeRect(rowX, 115, rowW, 95));
    outboxBox.setBoxType($.NSBoxCustom);
    outboxBox.setBorderType($.NSLineBorder);
    outboxBox.setBorderWidth(1.0);
    outboxBox.setBorderColor($.NSColor.separatorColor);
    outboxBox.setCornerRadius(8.0);
    outboxBox.setFillColor($.NSColor.controlBackgroundColor);
    wheelView.addSubview(outboxBox);

    // Big Icon on Left of Large Number
    createLabel("📤", 18, 16, 46, 60, false, 36, outboxBox, false);

    const outputCountLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(68, 12, 115, 68));
    outputCountLabel.setBezeled(false);
    outputCountLabel.setDrawsBackground(false);
    outputCountLabel.setEditable(false);
    outputCountLabel.setSelectable(false);
    outputCountLabel.setFont($.NSFont.boldSystemFontOfSize(48));
    setLeftText(outputCountLabel, "0", $.NSColor.systemGreenColor);
    outboxBox.addSubview(outputCountLabel);

    createLabel("Outbox", 195, 50, 220, 24, true, 16, outboxBox, false);
    const outDesc = createLabel("completed", 195, 26, 220, 18, false, 12, outboxBox, false);
    outDesc.setTextColor($.NSColor.secondaryLabelColor);
    const outputErrorLabel = createLabel("0 errors", 195, 8, 220, 16, false, 11, outboxBox, false);
    outputErrorLabel.setTextColor($.NSColor.secondaryLabelColor);

    const btnWheelOpenOutput = createButton("📂 Open Outbox", rowW - 155, 30, 135, 34, outboxBox);

    // --- Row 4: Footer ---
    const btnWheelOpenHome = createButton("🏠 Open Hamster Home", rowX, 35, 200, 34, wheelView);

    // =========================================================================
    // TAB 2: ⚙️ Settings Tab (Clean Flat Form Layout)
    // =========================================================================
    const tab2 = $.NSTabViewItem.alloc.init;
    tab2.label = "⚙️ Settings";
    const settingsView = $.NSView.alloc.initWithFrame(tabView.bounds);
    tab2.view = settingsView;
    tabView.addTabViewItem(tab2);

    const sTop = 450;

    // Display Name
    createLabel("Display Name:", 15, sTop, 120, 20, true, 12, settingsView, false);
    const displayNameField = createTextField(config.displayName, 140, sTop, 445, 22, settingsView);

    // Hamster Home Header (Label on left, action buttons on right)
    createLabel("Hamster Home:", 15, sTop - 35, 150, 20, true, 12, settingsView, false);
    const btnChooseHome = createButton("Choose…", 420, sTop - 37, 78, 26, settingsView);
    const btnOpenHome = createButton("📂 Open", 502, sTop - 37, 83, 26, settingsView);

    // Full Width Hamster Home Path Field
    const homeField = createTextField(config.homeFolder, 15, sTop - 63, 570, 22, settingsView);

    // Input Folder
    createLabel("Input (Inbox):", 15, sTop - 98, 120, 20, true, 12, settingsView, false);
    const inputField = createTextField(toDisplayPath(config.inputFolder, config.homeFolder), 140, sTop - 98, 275, 22, settingsView);
    const btnChooseInput = createButton("Choose…", 420, sTop - 100, 78, 26, settingsView);
    const btnOpenInput = createButton("📂 Open", 502, sTop - 100, 83, 26, settingsView);

    // Output Folder
    createLabel("Output (Outbox):", 15, sTop - 131, 120, 20, true, 12, settingsView, false);
    const outputField = createTextField(toDisplayPath(config.outputFolder, config.homeFolder), 140, sTop - 131, 275, 22, settingsView);
    const btnChooseOutput = createButton("Choose…", 420, sTop - 133, 78, 26, settingsView);
    const btnOpenOutput = createButton("📂 Open", 502, sTop - 133, 83, 26, settingsView);

    // AI Backend
    createLabel("AI Backend:", 15, sTop - 164, 120, 20, true, 12, settingsView, false);
    const agentPopup = $.NSPopUpButton.alloc.initWithFramePullsDown($.NSMakeRect(140, sTop - 167, 180, 26), false);
    agentPopup.addItemWithTitle("Gemini (" + (agyPath ? "Installed" : "Not Found") + ")");
    agentPopup.addItemWithTitle("Claude (" + (claudePath ? "Installed" : "Not Found") + ")");
    agentPopup.addItemWithTitle("Codex (" + (codexPath ? "Installed" : "Not Found") + ")");
    if (config.agent === "codex") {
        agentPopup.selectItemAtIndex(2);
    } else if (config.agent === "claude") {
        agentPopup.selectItemAtIndex(1);
    } else {
        agentPopup.selectItemAtIndex(0);
    }
    settingsView.addSubview(agentPopup);

    function getSelectedBackendPath() {
        if (config.agent === "codex") return codexPath || "Codex CLI not found";
        if (config.agent === "claude") return claudePath || "Claude CLI not found";
        return agyPath || "Gemini/Agy CLI not found";
    }

    createLabel(getSelectedBackendPath(), 330, sTop - 164, 255, 20, false, 10, settingsView, false);

    // Instructions
    createLabel("Instructions / Prompt Template:", 15, sTop - 194, 250, 20, true, 12, settingsView, false);
    const scrollInstr = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(15, sTop - 276, 570, 78));
    scrollInstr.setHasVerticalScroller(true);
    scrollInstr.setBorderType($.NSBezelBorder);

    const instrTextView = $.NSTextView.alloc.initWithFrame(scrollInstr.contentView.frame);
    instrTextView.setMinSize($.NSMakeSize(0.0, 78));
    instrTextView.setMaxSize($.NSMakeSize(10000.0, 10000.0));
    instrTextView.setVerticallyResizable(true);
    instrTextView.setHorizontallyResizable(false);
    instrTextView.setAutoresizingMask($.NSViewWidthSizable);
    instrTextView.setString(config.instructions || "");
    instrTextView.setFont($.NSFont.systemFontOfSize(12));
    scrollInstr.setDocumentView(instrTextView);
    settingsView.addSubview(scrollInstr);

    // Tools List
    createLabel("Tools Folders:", 15, sTop - 308, 120, 20, true, 12, settingsView, false);
    const toolsField = createTextField(config.tools.join("; "), 140, sTop - 308, 275, 22, settingsView);
    const btnAddTool = createButton("Add…", 420, sTop - 310, 78, 26, settingsView);
    const btnClearTools = createButton("Clear", 502, sTop - 310, 83, 26, settingsView);

    // Skills List
    createLabel("Skills Folders:", 15, sTop - 340, 120, 20, true, 12, settingsView, false);
    const skillsField = createTextField(config.skills.join("; "), 140, sTop - 340, 275, 22, settingsView);
    const btnAddSkill = createButton("Add…", 420, sTop - 342, 78, 26, settingsView);
    const btnClearSkills = createButton("Clear", 502, sTop - 342, 83, 26, settingsView);

    // Settings Footer Buttons
    const btnSave = createButton("💾 Save Configuration", 15, 20, 175, 36, settingsView);
    btnSave.setFont($.NSFont.boldSystemFontOfSize(13));

    const btnOpenStorage = createButton("⚙️ State Directory", 200, 20, 140, 36, settingsView);
    const settingsFeedbackLabel = createLabel("", 350, 28, 235, 20, false, 11, settingsView, false);

    // -------------------------------------------------------------------------
    // Worker State Engine & Real-Time Item Counts
    // -------------------------------------------------------------------------
    let isWorkerRunning = false;
    let currentTask = null;
    let activeClaimItem = null;
    let stabilityTracker = {};
    let processingStartedAt = null;
    let progressFrame = 0;
    const progressFrames = ["|", "/", "-", "\\"];

    function checkWorkerHeartbeat() {
        const homeDir = ObjC.unwrap(homeField.stringValue).trim() || config.homeFolder;
        const currentInDir = fromDisplayPath(ObjC.unwrap(inputField.stringValue), homeDir);
        const currentOutDir = fromDisplayPath(ObjC.unwrap(outputField.stringValue), homeDir);

        const inItems = listDir(currentInDir).filter(n => !n.startsWith(".") && !n.endsWith(".hamster_claim") && !n.endsWith(".tmp") && !isErrorFile(n));
        const outItems = listDir(currentOutDir).filter(n => !n.startsWith("."));
        const completedItems = outItems.filter(n => !isErrorFile(n));
        const errorItems = outItems.filter(n => isErrorFile(n));

        setLeftText(inputCountLabel, "" + inItems.length, $.NSColor.systemBlueColor);
        setLeftText(outputCountLabel, "" + completedItems.length, $.NSColor.systemGreenColor);
        setLeftText(outputErrorLabel, errorItems.length + " errors", errorItems.length > 0 ? $.NSColor.systemRedColor : $.NSColor.secondaryLabelColor);

        if (currentTask !== null) {
            if (!currentTask.isRunning) {
                const exitCode = currentTask.terminationStatus;
                const claimPath = activeClaimItem.claimPath;
                const origPath = activeClaimItem.origPath;
                const filename = activeClaimItem.filename;
                const stagingDir = hamsterDir + "/work/output_staging";
                const outDir = config.outputFolder;

                const stagingItems = listDir(stagingDir);
                let hadError = exitCode !== 0 || stagingItems.length === 0;
                let deliverySucceeded = true;

                for (let item of stagingItems) {
                    const src = stagingDir + "/" + item;
                    let dest = outDir + "/" + item;
                    if (hadError || fm.fileExistsAtPath(dest)) {
                        dest = errorOutputPath(outDir, item);
                        hadError = true;
                    }
                    if (!movePath(src, dest)) {
                        const errorDest = errorOutputPath(outDir, item);
                        if (!movePath(src, errorDest)) deliverySucceeded = false;
                        else hadError = true;
                    }
                }

                if (stagingItems.length === 0) {
                    const errorDest = errorOutputPath(outDir, filename);
                    writeText(errorDest, "Hamster produced no output. Exit code: " + exitCode + ". See last_run.log for agent output.\n");
                    if (!fm.fileExistsAtPath(errorDest)) deliverySucceeded = false;
                }

                if (deliverySucceeded && listDir(stagingDir).length === 0) {
                    if (fm.fileExistsAtPath(claimPath)) {
                        if (hadError) restoreClaim(claimPath, origPath);
                        else removePath(claimPath);
                    }
                    setCenterText(statusLabel, hadError ? "Error output: " + filename : "Done: " + filename, hadError ? $.NSColor.systemRedColor : $.NSColor.systemGreenColor);
                } else {
                    setCenterText(statusLabel, "Error delivering: " + filename, $.NSColor.systemRedColor);
                }

                setWorkerStateIndicator(false);
                appendLog("\n=== Run finished " + new Date().toISOString() + " (exit " + exitCode + ") ===\n");
                currentTask = null;
                activeClaimItem = null;
                processingStartedAt = null;
                progressDetailLabel.setStringValue("");
            } else if (activeClaimItem && processingStartedAt !== null) {
                setWorkerStateIndicator(true);
                const elapsed = (Date.now() - processingStartedAt) / 1000;
                const frame = progressFrames[progressFrame % progressFrames.length];
                progressFrame++;
                setCenterText(statusLabel, frame + " Processing", $.NSColor.systemOrangeColor);
                const logAttrs = getAttrs(logFile);
                const logSize = logAttrs ? (logAttrs.objectForKey($.NSFileSize).js || 0) : 0;
                setLeftText(progressDetailLabel, activeClaimItem.filename + " · " + formatDuration(elapsed) + " · log " + formatBytes(Number(logSize)), $.NSColor.secondaryLabelColor);
            }
            return;
        }

        const isRunning = getWorkerState();
        if (!isRunning) {
            btnStartStop.setTitle("▶ Start Hamster");
            setWorkerStateIndicator(false);
            setCenterText(statusLabel, "", $.NSColor.secondaryLabelColor);
            progressDetailLabel.setStringValue("");
            return;
        }
        btnStartStop.setTitle("⏹ Stop Hamster");
        if (!currentTask) {
            setWorkerStateIndicator(false);
            if (statusLabel.stringValue.js === "Stopped" || statusLabel.stringValue.js === "Idle (Watching)") {
                setCenterText(statusLabel, "", $.NSColor.secondaryLabelColor);
            }
            progressDetailLabel.setStringValue("");
        }

        const inDir = config.inputFolder;
        if (!inDir || !fm.fileExistsAtPath(inDir)) return;

        const items = listDir(inDir);
        if (items.length === 0) {
            return;
        }

        let selectedItem = null;

        for (let name of items) {
            if (name.startsWith(".") || name.endsWith(".hamster_claim") || name.endsWith(".tmp") || isErrorFile(name)) {
                continue;
            }
            const fullPath = inDir + "/" + name;
            const attrs = getAttrs(fullPath);
            if (!attrs) continue;

            const size = attrs.objectForKey($.NSFileSize).js || 0;
            const mtime = attrs.objectForKey($.NSFileModificationDate).timeIntervalSince1970.js || 0;

            const prev = stabilityTracker[fullPath];
            if (prev && prev.size === size && prev.mtime === mtime) {
                selectedItem = { name: name, path: fullPath };
                delete stabilityTracker[fullPath];
                break;
            } else {
                stabilityTracker[fullPath] = { size: size, mtime: mtime };
            }
        }

        if (!selectedItem) {
            return;
        }

        const filename = selectedItem.name;
        const claimPath = hamsterDir + "/work/claim/" + filename;
        const stagingDir = hamsterDir + "/work/output_staging";

        if (listDir(stagingDir).length > 0) {
            setCenterText(statusLabel, "Unfinished output needs review", $.NSColor.systemRedColor);
            return;
        }
        if (fm.fileExistsAtPath(claimPath)) {
            setCenterText(statusLabel, "Unfinished claim needs review", $.NSColor.systemRedColor);
            return;
        }
        const moveSuccess = movePath(selectedItem.path, claimPath);
        if (!moveSuccess) {
            setCenterText(statusLabel, "Claim failed: " + filename, $.NSColor.systemRedColor);
            return;
        }

        activeClaimItem = {
            filename: filename,
            origPath: selectedItem.path,
            claimPath: claimPath
        };

        setWorkerStateIndicator(true);
        setCenterText(statusLabel, "| Processing", $.NSColor.systemOrangeColor);
        progressDetailLabel.setStringValue(filename + " · starting…");
        processingStartedAt = Date.now();
        progressFrame = 1;

        let prompt = "Instructions:\n" + config.instructions + "\n\n";
        prompt += "Input item path: " + claimPath + "\n";
        prompt += "Output destination directory: " + stagingDir + "\n";
        prompt += "Please read the input item, perform the transformation, and write the output files into the output destination directory.\n";

        if (config.tools.length > 0) {
            prompt += "\nTools available in folders:\n" + config.tools.join("\n") + "\n";
        }
        if (config.skills.length > 0) {
            prompt += "\nSkills available in folders:\n" + config.skills.join("\n") + "\n";
        }

        const task = $.NSTask.alloc.init;
        task.setLaunchPath("/bin/zsh");

        let agentCmd = "";
        let addDirArgs = "";
        config.tools.concat(config.skills).forEach(d => {
            if (d) addDirArgs += " --add-dir " + shellQuote(d);
        });

        if (config.agent === "codex" && codexPath) {
            agentCmd = shellQuote(codexPath) + " exec " + shellQuote(prompt) + " --cd " + shellQuote(stagingDir) + addDirArgs + " >> " + shellQuote(logFile) + " 2>&1";
        } else if (config.agent === "claude" && claudePath) {
            agentCmd = "cd " + shellQuote(stagingDir) + " && " + shellQuote(claudePath) + " -p --dangerously-skip-permissions " + shellQuote(prompt) + " >> " + shellQuote(logFile) + " 2>&1";
        } else if (config.agent === "gemini" && agyPath) {
            agentCmd = shellQuote(agyPath) + " --dangerously-skip-permissions --print=" + shellQuote(prompt) + addDirArgs + " >> " + shellQuote(logFile) + " 2>&1";
        } else {
            restoreClaim(claimPath, selectedItem.path);
            activeClaimItem = null;
            setCenterText(statusLabel, "Selected CLI not found", $.NSColor.systemRedColor);
            return;
        }

        writeText(logFile, "=== Run started " + new Date().toISOString() + " ===\nInput: " + claimPath + "\nOutput staging: " + stagingDir + "\nBackend: " + config.agent + "\n\n");
        task.setArguments($([ "-c", agentCmd ]));
        task.launch;
        currentTask = task;
    }

    // -------------------------------------------------------------------------
    // Actions & App Delegate
    // -------------------------------------------------------------------------
    ObjC.registerSubclass({
        name: "HamsterTabCoordinatorV9",
        methods: {
            "onChooseHome:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const panel = $.NSOpenPanel.openPanel;
                    panel.canChooseFiles = false;
                    panel.canChooseDirectories = true;
                    panel.allowsMultipleSelection = false;
                    panel.setMessage("Choose Hamster Home Directory");
                    if (panel.runModal == $.NSModalResponseOK) {
                        const chosen = ObjC.unwrap(panel.URLs.objectAtIndex(0).path);
                        homeField.setStringValue(chosen);
                        config.homeFolder = chosen;

                        config.inputFolder = fromDisplayPath(ObjC.unwrap(inputField.stringValue), chosen);
                        config.outputFolder = fromDisplayPath(ObjC.unwrap(outputField.stringValue), chosen);

                        inputField.setStringValue(toDisplayPath(config.inputFolder, chosen));
                        outputField.setStringValue(toDisplayPath(config.outputFolder, chosen));

                        makeDir(config.homeFolder);
                        makeDir(config.inputFolder);
                        makeDir(config.outputFolder);
                        saveConfig();
                    }
                }
            },
            "onOpenHome:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const path = ObjC.unwrap(homeField.stringValue).trim() || config.homeFolder;
                    if (path) {
                        makeDir(path);
                        $.NSWorkspace.sharedWorkspace.openFile(path);
                    }
                }
            },
            "onChooseInput:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const panel = $.NSOpenPanel.openPanel;
                    panel.canChooseFiles = false;
                    panel.canChooseDirectories = true;
                    panel.allowsMultipleSelection = false;
                    panel.setMessage("Choose Input (Inbox) Folder for Hamster");
                    if (panel.runModal == $.NSModalResponseOK) {
                        const chosen = ObjC.unwrap(panel.URLs.objectAtIndex(0).path);
                        config.inputFolder = chosen;
                        inputField.setStringValue(toDisplayPath(chosen, config.homeFolder));
                        saveConfig();
                    }
                }
            },
            "onOpenInput:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const fullPath = fromDisplayPath(ObjC.unwrap(inputField.stringValue), config.homeFolder);
                    if (fullPath) {
                        makeDir(fullPath);
                        $.NSWorkspace.sharedWorkspace.openFile(fullPath);
                    }
                }
            },
            "onChooseOutput:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const panel = $.NSOpenPanel.openPanel;
                    panel.canChooseFiles = false;
                    panel.canChooseDirectories = true;
                    panel.allowsMultipleSelection = false;
                    panel.setMessage("Choose Output (Outbox) Folder for Hamster");
                    if (panel.runModal == $.NSModalResponseOK) {
                        const chosen = ObjC.unwrap(panel.URLs.objectAtIndex(0).path);
                        config.outputFolder = chosen;
                        outputField.setStringValue(toDisplayPath(chosen, config.homeFolder));
                        saveConfig();
                    }
                }
            },
            "onOpenOutput:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const fullPath = fromDisplayPath(ObjC.unwrap(outputField.stringValue), config.homeFolder);
                    if (fullPath) {
                        makeDir(fullPath);
                        $.NSWorkspace.sharedWorkspace.openFile(fullPath);
                    }
                }
            },
            "onAddTool:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const panel = $.NSOpenPanel.openPanel;
                    panel.canChooseFiles = false;
                    panel.canChooseDirectories = true;
                    if (panel.runModal == $.NSModalResponseOK) {
                        const chosen = ObjC.unwrap(panel.URLs.objectAtIndex(0).path);
                        if (!config.tools.includes(chosen)) {
                            config.tools.push(chosen);
                            toolsField.setStringValue(config.tools.join("; "));
                            saveConfig();
                        }
                    }
                }
            },
            "onClearTools:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    config.tools = [];
                    toolsField.setStringValue("");
                    saveConfig();
                }
            },
            "onAddSkill:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const panel = $.NSOpenPanel.openPanel;
                    panel.canChooseFiles = false;
                    panel.canChooseDirectories = true;
                    if (panel.runModal == $.NSModalResponseOK) {
                        const chosen = ObjC.unwrap(panel.URLs.objectAtIndex(0).path);
                        if (!config.skills.includes(chosen)) {
                            config.skills.push(chosen);
                            skillsField.setStringValue(config.skills.join("; "));
                            saveConfig();
                        }
                    }
                }
            },
            "onClearSkills:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    config.skills = [];
                    skillsField.setStringValue("");
                    saveConfig();
                }
            },
            "onStartStop:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const currentlyRunning = getWorkerState();
                    if (!currentlyRunning) {
                        const homeDir = ObjC.unwrap(homeField.stringValue).trim() || config.homeFolder;
                        const inDir = fromDisplayPath(ObjC.unwrap(inputField.stringValue), homeDir);
                        const outDir = fromDisplayPath(ObjC.unwrap(outputField.stringValue), homeDir);

                        if (!inDir) {
                            setCenterText(statusLabel, "Missing Inbox", $.NSColor.systemRedColor);
                            return;
                        }
                        if (!outDir) {
                            setCenterText(statusLabel, "Missing Outbox", $.NSColor.systemRedColor);
                            return;
                        }

                        if (homeDir) makeDir(homeDir);
                        makeDir(inDir);
                        makeDir(outDir);

                        config.displayName = ObjC.unwrap(displayNameField.stringValue).trim() || defaultDisplayName;
                        config.homeFolder = homeDir;
                        config.inputFolder = inDir;
                        config.outputFolder = outDir;
                        config.instructions = ObjC.unwrap(instrTextView.string);
                        const selAgent = agentPopup.indexOfSelectedItem;
                        config.agent = (selAgent === 2 ? "codex" : (selAgent === 1 ? "claude" : "gemini"));
                        saveConfig();

                        headerTitleLabel.setStringValue("🐹 " + config.displayName);
                        win.setTitle("🐹 " + config.displayName + " (" + hamsterId + ")");

                        setWorkerState(true);
                        btnStartStop.setTitle("⏹ Stop Hamster");
                        setWorkerStateIndicator(false);
                        setCenterText(statusLabel, "", $.NSColor.secondaryLabelColor);
                    } else {
                        setWorkerState(false);
                        btnStartStop.setTitle("▶ Start Hamster");
                        setWorkerStateIndicator(false);
                        setCenterText(statusLabel, "", $.NSColor.secondaryLabelColor);
                    }
                }
            },
            "onSave:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    config.displayName = ObjC.unwrap(displayNameField.stringValue).trim() || defaultDisplayName;
                    config.homeFolder = ObjC.unwrap(homeField.stringValue).trim() || config.homeFolder;
                    config.inputFolder = fromDisplayPath(ObjC.unwrap(inputField.stringValue), config.homeFolder);
                    config.outputFolder = fromDisplayPath(ObjC.unwrap(outputField.stringValue), config.homeFolder);
                    config.instructions = ObjC.unwrap(instrTextView.string);
                    config.tools = ObjC.unwrap(toolsField.stringValue).split(";").map(function(path) {
                        return path.trim();
                    }).filter(function(path) {
                        return path.length > 0;
                    });
                    config.skills = ObjC.unwrap(skillsField.stringValue).split(";").map(function(path) {
                        return path.trim();
                    }).filter(function(path) {
                        return path.length > 0;
                    });
                    const selAgent = agentPopup.indexOfSelectedItem;
                    config.agent = (selAgent === 2 ? "codex" : (selAgent === 1 ? "claude" : "gemini"));
                    saveConfig();
                    headerTitleLabel.setStringValue("🐹 " + config.displayName);
                    win.setTitle("🐹 " + config.displayName + " (" + hamsterId + ")");
                    settingsFeedbackLabel.setStringValue("Saved at " + new Date().toLocaleTimeString());
                }
            },
            "onCreateHamster:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const currentDir = workerDir.substring(0, workerDir.lastIndexOf("/"));
                    let newId;
                    do {
                        newId = "hamster-" + $.NSUUID.UUID.UUIDString.js.toLowerCase().substring(0, 8);
                    } while (fm.fileExistsAtPath(currentDir + "/" + newId));
                    const newHamsterDir = currentDir + "/" + newId;
                    const destPath = newHamsterDir + "/hamster.command";

                    makeDir(newHamsterDir);

                    const ownCode = $.NSString.stringWithContentsOfFileEncodingError(scriptPath, $.NSUTF8StringEncoding, $());
                    let codeStr = ObjC.unwrap(ownCode);
                    codeStr = codeStr.replace(/HAMSTER_ID="[^"]*"/, 'HAMSTER_ID="' + newId + '"');

                    const nsCode = $.NSString.stringWithString(codeStr);
                    nsCode.writeToFileAtomicallyEncodingError(destPath, true, $.NSUTF8StringEncoding, $());

                    for (let asset of ["instructions", "skills", "tools"]) {
                        const sourceAsset = workerDir + "/" + asset;
                        if (fm.fileExistsAtPath(sourceAsset)) {
                            fm.copyItemAtPathToPathError(sourceAsset, newHamsterDir + "/" + asset, $());
                        }
                    }

                    const task = $.NSTask.alloc.init;
                    task.setLaunchPath("/bin/chmod");
                    task.setArguments($([ "+x", destPath ]));
                    task.launch;
                    task.waitUntilExit;

                    makeDir(newHamsterDir + "/work/claim");
                    makeDir(newHamsterDir + "/work/output_staging");

                    const newName = "Hamster " + newId.replace("hamster-", "");
                    const newHome = newHamsterDir;
                    const newInbox = newHamsterDir + "/input";
                    const newOutbox = newHamsterDir + "/output";

                    makeDir(newHome);
                    makeDir(newInbox);
                    makeDir(newOutbox);

                    const newConfig = Object.assign({}, config, {
                        name: newName,
                        homeFolder: newHome,
                        inputFolder: newInbox,
                        outputFolder: newOutbox,
                        tools: [newHamsterDir + "/tools"],
                        skills: [newHamsterDir + "/skills"]
                    });

                    const newConfigStr = $.NSString.stringWithString(JSON.stringify(newConfig, null, 2));
                    newConfigStr.writeToFileAtomicallyEncodingError(
                        newHamsterDir + "/.hamster/config.json", true, $.NSUTF8StringEncoding, $()
                    );
                    makeDir(newHamsterDir + "/instructions");
                    writeText(newHamsterDir + "/instructions/prompt.md", config.instructions + "\n");

                    $.NSWorkspace.sharedWorkspace.openFile(destPath);
                }
            },
            "onOpenStorage:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    $.NSWorkspace.sharedWorkspace.openFile(hamsterDir);
                }
            },
            "onViewLog:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    if (fm.fileExistsAtPath(logFile)) {
                        $.NSWorkspace.sharedWorkspace.openFile(logFile);
                    }
                }
            },
            "onTimerTick:": {
                types: ["void", ["id"]],
                implementation: function(timer) {
                    checkWorkerHeartbeat();
                }
            },
            "windowShouldClose:": {
                types: ["bool", ["id"]],
                implementation: function(sender) {
                    const isRunning = getWorkerState();
                    if (isRunning) {
                        const alert = $.NSAlert.alloc.init;
                        alert.setMessageText("Hamster is running");
                        alert.setInformativeText("Do you want to stop the Hamster, or keep it running in the background?");
                        alert.addButtonWithTitle("Keep Running in Background");
                        alert.addButtonWithTitle("Stop and Close");
                        alert.addButtonWithTitle("Cancel");

                        const response = alert.runModal;
                        if (response === $.NSAlertFirstButtonReturn) {
                            win.orderOut(null);
                            app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
                            return false;
                        } else if (response === $.NSAlertSecondButtonReturn) {
                            setWorkerState(false);
                            if (currentTask && currentTask.isRunning) {
                                currentTask.terminate;
                            }
                            if (activeClaimItem && fm.fileExistsAtPath(activeClaimItem.claimPath)) {
                                restoreClaim(activeClaimItem.claimPath, activeClaimItem.origPath);
                            }
                            removePath(pidFile);
                            app.terminate(null);
                            return true;
                        } else {
                            return false;
                        }
                    } else {
                        removePath(pidFile);
                        app.terminate(null);
                        return true;
                    }
                }
            },
            "applicationShouldHandleReopen:hasVisibleWindows:": {
                types: ["bool", ["id", "bool"]],
                implementation: function(sender, flag) {
                    app.setActivationPolicy($.NSApplicationActivationPolicyRegular);
                    win.makeKeyAndOrderFront(null);
                    win.orderFrontRegardless;
                    app.activateIgnoringOtherApps(true);
                    return true;
                }
            }
        }
    });

    const coordinator = $.HamsterTabCoordinatorV9.alloc.init;
    app.setDelegate(coordinator);
    win.setDelegate(coordinator);

    // Bind Tab 1 Buttons
    btnWheelOpenInput.setTarget(coordinator);
    btnWheelOpenInput.setAction("onOpenInput:");

    btnWheelOpenOutput.setTarget(coordinator);
    btnWheelOpenOutput.setAction("onOpenOutput:");

    btnStartStop.setTarget(coordinator);
    btnStartStop.setAction("onStartStop:");

    btnWheelViewLog.setTarget(coordinator);
    btnWheelViewLog.setAction("onViewLog:");

    btnWheelCreateHamster.setTarget(coordinator);
    btnWheelCreateHamster.setAction("onCreateHamster:");

    btnWheelOpenHome.setTarget(coordinator);
    btnWheelOpenHome.setAction("onOpenHome:");

    // Bind Tab 2 Buttons
    btnChooseHome.setTarget(coordinator);
    btnChooseHome.setAction("onChooseHome:");

    btnOpenHome.setTarget(coordinator);
    btnOpenHome.setAction("onOpenHome:");

    btnChooseInput.setTarget(coordinator);
    btnChooseInput.setAction("onChooseInput:");

    btnOpenInput.setTarget(coordinator);
    btnOpenInput.setAction("onOpenInput:");

    btnChooseOutput.setTarget(coordinator);
    btnChooseOutput.setAction("onChooseOutput:");

    btnOpenOutput.setTarget(coordinator);
    btnOpenOutput.setAction("onOpenOutput:");

    btnAddTool.setTarget(coordinator);
    btnAddTool.setAction("onAddTool:");

    btnClearTools.setTarget(coordinator);
    btnClearTools.setAction("onClearTools:");

    btnAddSkill.setTarget(coordinator);
    btnAddSkill.setAction("onAddSkill:");

    btnClearSkills.setTarget(coordinator);
    btnClearSkills.setAction("onClearSkills:");

    btnSave.setTarget(coordinator);
    btnSave.setAction("onSave:");

    btnOpenStorage.setTarget(coordinator);
    btnOpenStorage.setAction("onOpenStorage:");

    // Start 0.5s RunLoop Timer for live count updates & worker heartbeat
    const timer = $.NSTimer.scheduledTimerWithTimeIntervalTargetSelectorUserInfoRepeats(
        0.5, coordinator, "onTimerTick:", null, true
    );
    $.NSRunLoop.currentRunLoop.addTimerForMode(timer, $.NSRunLoopCommonModes);

    // Show window unless launched in headless mode
    const isHeadless = argv.some(a => a === "--headless");
    if (!isHeadless) {
        win.makeKeyAndOrderFront(null);
        win.orderFrontRegardless;
        app.activateIgnoringOtherApps(true);
    } else {
        app.setActivationPolicy($.NSApplicationActivationPolicyAccessory);
    }

    // Start Native Cocoa Run Loop
    app.run;
}
EOF
