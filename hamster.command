#!/bin/bash
# ==============================================================================
# 🐹 HAMSTER - Single-File macOS Autonomous Worker Prototype
# ==============================================================================
# Hard Constraints:
# - Entire app contained in this single .command file.
# - No external packages or compilers; uses macOS native zsh/bash, JXA & AppKit.
# - Persistent independent state per Hamster under ~/Library/Application Support/Hamsters/<HAMSTER_ID>/
# - Simplified, elegant 2-Tab Layout without heavy nested frames.
# - Tab 1: 🐹 Hamster Wheel (3 clean columns with all texts perfectly centered)
# - Tab 2: ⚙️ Settings (Clean configuration layout)
# - Safe claiming, processing, and atomic output finalization.
# - Native Cocoa event loop (app.run) for instantaneous UI responsiveness.
# - Full Dock, Cmd+Tab, and Menu Bar integration.
# ==============================================================================

# Ensure common CLI paths are available even when launched from Finder
export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$HOME/.gemini/bin:$HOME/.codex/bin:$HOME/bin:$PATH"

# Persistent Unique Hamster Identity placeholder (auto-populated on first run or clone)
HAMSTER_ID="hamster-f6b5941e"

# Canonical path to this script
SCRIPT_PATH="$(cd "$(dirname "$0")" && pwd)/$(basename "$0")"

# Base storage directory
BASE_STORAGE="$HOME/Library/Application Support/Hamsters"

# ------------------------------------------------------------------------------
# 1. Identity Initialization & Self-Healing Clone Detection
# ------------------------------------------------------------------------------
if [ "$HAMSTER_ID" = "HAMSTER_ID_PLACEHOLDER" ] || [ -z "$HAMSTER_ID" ]; then
    NEW_ID="hamster-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
    HAMSTER_ID="$NEW_ID"
    # Update own file to lock in identity
    sed -i '' "s/HAMSTER_ID=\"HAMSTER_ID_PLACEHOLDER\"/HAMSTER_ID=\"$NEW_ID\"/g" "$SCRIPT_PATH" 2>/dev/null || true
fi

HAMSTER_DIR="$BASE_STORAGE/$HAMSTER_ID"
LOC_FILE="$HAMSTER_DIR/location.txt"
PID_FILE="$HAMSTER_DIR/app.pid"

# If state folder exists but points to a different physical path, this file was manually duplicated in Finder!
if [ -f "$LOC_FILE" ]; then
    REGISTERED_PATH=$(cat "$LOC_FILE" 2>/dev/null)
    if [ "$REGISTERED_PATH" != "$SCRIPT_PATH" ] && [ -n "$REGISTERED_PATH" ]; then
        # Spawn a new independent ID for this clone
        CLONE_ID="hamster-$(uuidgen | tr '[:upper:]' '[:lower:]' | cut -c1-8)"
        sed -i '' "s/HAMSTER_ID=\"$HAMSTER_ID\"/HAMSTER_ID=\"$CLONE_ID\"/g" "$SCRIPT_PATH" 2>/dev/null || true
        HAMSTER_ID="$CLONE_ID"
        HAMSTER_DIR="$BASE_STORAGE/$HAMSTER_ID"
        LOC_FILE="$HAMSTER_DIR/location.txt"
        PID_FILE="$HAMSTER_DIR/app.pid"
    fi
fi

mkdir -p "$HAMSTER_DIR/work/claim" "$HAMSTER_DIR/work/output_staging"
echo "$SCRIPT_PATH" > "$LOC_FILE"

# ------------------------------------------------------------------------------
# 2. Single-Instance Enforcement per Hamster
# ------------------------------------------------------------------------------
if [ -f "$PID_FILE" ]; then
    EXISTING_PID=$(cat "$PID_FILE" 2>/dev/null)
    if [ -n "$EXISTING_PID" ] && kill -0 "$EXISTING_PID" 2>/dev/null; then
        # Bring existing instance to the front
        osascript -e "
        tell application \"System Events\"
            set pList to (every process whose unix id is $EXISTING_PID)
            if (count of pList) > 0 then
                set frontmost of (item 1 of pList) to true
            end if
        end tell
        " 2>/dev/null || true
        exit 0
    fi
fi

# ------------------------------------------------------------------------------
# 3. Clean Launch Hand-Off (Direct process replacement with JXA)
# ------------------------------------------------------------------------------
exec /usr/bin/osascript -l JavaScript - "$HAMSTER_ID" "$HAMSTER_DIR" "$SCRIPT_PATH" << 'EOF'
function run(argv) {
    ObjC.import("Cocoa");

    const hamsterId = argv[0];
    const hamsterDir = argv[1];
    const scriptPath = argv[2];
    const configFile = hamsterDir + "/config.json";
    const logFile = hamsterDir + "/last_run.log";
    const pidFile = hamsterDir + "/app.pid";

    const fm = $.NSFileManager.defaultManager;
    const userHome = "/Users/" + $.NSUserName().js;

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

    function getAttrs(path) {
        if (!path || !fm.fileExistsAtPath(path)) return null;
        return fm.attributesOfItemAtPathError(path, $());
    }

    function cleanDir(dir) {
        const items = listDir(dir);
        for (let item of items) {
            removePath(dir + "/" + item);
        }
    }

    function toDisplayPath(fullPath, homePath) {
        if (!fullPath) return "";
        const cleanFull = fullPath.replace(/\/+$/, "");
        const cleanHome = (homePath || "").replace(/\/+$/, "");
        if (cleanHome && cleanFull.startsWith(cleanHome + "/")) {
            return cleanFull.substring(cleanHome.length + 1);
        }
        if (cleanHome && cleanFull === cleanHome) {
            return ".";
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
        if (trimmed === "." || trimmed === "") {
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
    const safeDefaultName = defaultName.replace(/\s+/g, "_");
    const defaultHome = userHome + "/Hamsters/" + safeDefaultName;
    const defaultInbox = defaultHome + "/inbox";
    const defaultOutbox = defaultHome + "/outbox";

    let config = {
        name: defaultName,
        homeFolder: defaultHome,
        inputFolder: defaultInbox,
        outputFolder: defaultOutbox,
        agent: "gemini",
        instructions: "Read the input file. Process it according to the requested transformation, and write the resulting output file to the specified output folder.",
        tools: [],
        skills: []
    };

    if (fm.fileExistsAtPath(configFile)) {
        try {
            const data = $.NSString.stringWithContentsOfFileEncodingError(configFile, $.NSUTF8StringEncoding, $());
            const parsed = JSON.parse(ObjC.unwrap(data));
            config = Object.assign(config, parsed);
        } catch (e) {}
    }

    if (!config.homeFolder) config.homeFolder = defaultHome;
    if (!config.inputFolder) config.inputFolder = defaultInbox;
    if (!config.outputFolder) config.outputFolder = defaultOutbox;

    makeDir(config.homeFolder);
    makeDir(config.inputFolder);
    makeDir(config.outputFolder);

    function saveConfig() {
        const jsonStr = JSON.stringify(config, null, 2);
        const nsStr = $.NSString.stringWithString(jsonStr);
        nsStr.writeToFileAtomicallyEncodingError(configFile, true, $.NSUTF8StringEncoding, $());
    }

    // CLI Detection
    function detectCLI(name) {
        const paths = [
            "/usr/local/bin/" + name,
            "/opt/homebrew/bin/" + name,
            userHome + "/.local/bin/" + name,
            userHome + "/.gemini/bin/" + name,
            userHome + "/.codex/bin/" + name,
            "/usr/bin/" + name
        ];
        for (let p of paths) {
            if (fm.isExecutableFileAtPath(p)) return p;
        }
        return null;
    }

    const agyPath = detectCLI("agy") || detectCLI("gemini");
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

    win.setTitle("🐹 " + config.name + " (" + hamsterId + ")");
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
    createLabel("🐹 " + config.name, 20, winHeight - 36, 350, 22, true, 16, contentView, false);
    createLabel("ID: " + hamsterId, winWidth - 220, winHeight - 34, 200, 18, false, 11, contentView, false);

    // Tab View
    const tabView = $.NSTabView.alloc.initWithFrame($.NSMakeRect(15, 10, winWidth - 30, winHeight - 50));
    contentView.addSubview(tabView);

    // =========================================================================
    // TAB 1: 🐹 Hamster Wheel (All texts centered per column)
    // =========================================================================
    const tab1 = $.NSTabViewItem.alloc.init;
    tab1.label = "🐹 Hamster Wheel";
    const wheelView = $.NSView.alloc.initWithFrame(tabView.bounds);
    tab1.view = wheelView;
    tabView.addTabViewItem(tab1);

    const colW = 190;
    const col1X = 15;
    const col2X = 215;
    const col3X = 415;

    // --- Column 1: Input (Inbox) ---
    createLabel("📥 Input (Inbox)", col1X, 415, colW, 24, true, 15, wheelView, true);

    const inputCountLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(col1X, 335, colW, 65));
    inputCountLabel.setBezeled(false);
    inputCountLabel.setDrawsBackground(false);
    inputCountLabel.setEditable(false);
    inputCountLabel.setSelectable(false);
    inputCountLabel.setFont($.NSFont.boldSystemFontOfSize(52));
    setCenterText(inputCountLabel, "0", $.NSColor.systemBlueColor);
    wheelView.addSubview(inputCountLabel);

    createLabel("items in queue", col1X, 305, colW, 18, false, 12, wheelView, true);

    createLabel("FOLDER", col1X, 260, colW, 16, true, 10, wheelView, true);

    const inputPathDisplay = $.NSTextField.alloc.initWithFrame($.NSMakeRect(col1X, 238, colW, 20));
    inputPathDisplay.setBezeled(false);
    inputPathDisplay.setDrawsBackground(false);
    inputPathDisplay.setEditable(false);
    inputPathDisplay.setSelectable(false);
    inputPathDisplay.setFont($.NSFont.systemFontOfSize(12));
    setCenterText(inputPathDisplay, toDisplayPath(config.inputFolder, config.homeFolder), $.NSColor.secondaryLabelColor);
    wheelView.addSubview(inputPathDisplay);

    const btnWheelOpenInput = createButton("📂 Open Inbox", col1X + 20, 180, 150, 34, wheelView);

    // --- Column 2: Controls & Status ---
    createLabel("⚙️ Wheel Controls", col2X, 415, colW, 24, true, 15, wheelView, true);

    const btnStartStop = createButton("▶ Start Hamster", col2X + 15, 345, 160, 44, wheelView);
    btnStartStop.setFont($.NSFont.boldSystemFontOfSize(14));

    createLabel("STATUS", col2X, 310, colW, 16, true, 10, wheelView, true);

    const statusLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(col2X, 290, colW, 20));
    statusLabel.setBezeled(false);
    statusLabel.setDrawsBackground(false);
    statusLabel.setEditable(false);
    statusLabel.setSelectable(false);
    statusLabel.setFont($.NSFont.boldSystemFontOfSize(13));
    setCenterText(statusLabel, "Stopped", $.NSColor.secondaryLabelColor);
    wheelView.addSubview(statusLabel);

    createLabel("CURRENT ITEM", col2X, 260, colW, 16, true, 10, wheelView, true);

    const itemLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(col2X, 240, colW, 20));
    itemLabel.setBezeled(false);
    itemLabel.setDrawsBackground(false);
    itemLabel.setEditable(false);
    itemLabel.setSelectable(false);
    itemLabel.setFont($.NSFont.systemFontOfSize(11));
    setCenterText(itemLabel, "None", null);
    wheelView.addSubview(itemLabel);

    const detailsLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(col2X, 215, colW, 18));
    detailsLabel.setBezeled(false);
    detailsLabel.setDrawsBackground(false);
    detailsLabel.setEditable(false);
    detailsLabel.setSelectable(false);
    detailsLabel.setFont($.NSFont.systemFontOfSize(10));
    setCenterText(detailsLabel, "Idle", $.NSColor.secondaryLabelColor);
    wheelView.addSubview(detailsLabel);

    const btnWheelViewLog = createButton("📄 View Last Log", col2X + 20, 175, 150, 32, wheelView);
    const btnWheelCreateHamster = createButton("✨ Breed Hamster", col2X + 20, 135, 150, 32, wheelView);

    // --- Column 3: Output (Outbox) ---
    createLabel("📤 Output (Outbox)", col3X, 415, colW, 24, true, 15, wheelView, true);

    const outputCountLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(col3X, 335, colW, 65));
    outputCountLabel.setBezeled(false);
    outputCountLabel.setDrawsBackground(false);
    outputCountLabel.setEditable(false);
    outputCountLabel.setSelectable(false);
    outputCountLabel.setFont($.NSFont.boldSystemFontOfSize(52));
    setCenterText(outputCountLabel, "0", $.NSColor.systemGreenColor);
    wheelView.addSubview(outputCountLabel);

    createLabel("items finished", col3X, 305, colW, 18, false, 12, wheelView, true);

    createLabel("FOLDER", col3X, 260, colW, 16, true, 10, wheelView, true);

    const outputPathDisplay = $.NSTextField.alloc.initWithFrame($.NSMakeRect(col3X, 238, colW, 20));
    outputPathDisplay.setBezeled(false);
    outputPathDisplay.setDrawsBackground(false);
    outputPathDisplay.setEditable(false);
    outputPathDisplay.setSelectable(false);
    outputPathDisplay.setFont($.NSFont.systemFontOfSize(12));
    setCenterText(outputPathDisplay, toDisplayPath(config.outputFolder, config.homeFolder), $.NSColor.secondaryLabelColor);
    wheelView.addSubview(outputPathDisplay);

    const btnWheelOpenOutput = createButton("📂 Open Outbox", col3X + 20, 180, 150, 34, wheelView);

    // Footer
    const btnWheelOpenHome = createButton("🏠 Open Hamster Home", 15, 20, 180, 30, wheelView);
    createLabel("The filesystem is the queue. Items process sequentially.", 210, 25, 400, 20, false, 11, wheelView, false);

    // =========================================================================
    // TAB 2: ⚙️ Settings Tab (Clean Flat Form Layout)
    // =========================================================================
    const tab2 = $.NSTabViewItem.alloc.init;
    tab2.label = "⚙️ Settings";
    const settingsView = $.NSView.alloc.initWithFrame(tabView.bounds);
    tab2.view = settingsView;
    tabView.addTabViewItem(tab2);

    const sTop = 445;

    // Hamster Home Header (Label on left, action buttons on right)
    createLabel("Hamster Home:", 15, sTop, 150, 20, true, 12, settingsView, false);
    const btnChooseHome = createButton("Choose…", 420, sTop - 2, 78, 26, settingsView);
    const btnOpenHome = createButton("📂 Open", 502, sTop - 2, 83, 26, settingsView);

    // Full Width Hamster Home Path Field
    const homeField = createTextField(config.homeFolder, 15, sTop - 28, 570, 22, settingsView);

    // Input Folder
    createLabel("Input (Inbox):", 15, sTop - 65, 120, 20, true, 12, settingsView, false);
    const inputField = createTextField(toDisplayPath(config.inputFolder, config.homeFolder), 140, sTop - 65, 275, 22, settingsView);
    const btnChooseInput = createButton("Choose…", 420, sTop - 67, 78, 26, settingsView);
    const btnOpenInput = createButton("📂 Open", 502, sTop - 67, 83, 26, settingsView);

    // Output Folder
    createLabel("Output (Outbox):", 15, sTop - 100, 120, 20, true, 12, settingsView, false);
    const outputField = createTextField(toDisplayPath(config.outputFolder, config.homeFolder), 140, sTop - 100, 275, 22, settingsView);
    const btnChooseOutput = createButton("Choose…", 420, sTop - 102, 78, 26, settingsView);
    const btnOpenOutput = createButton("📂 Open", 502, sTop - 102, 83, 26, settingsView);

    // AI Backend
    createLabel("AI Backend:", 15, sTop - 135, 120, 20, true, 12, settingsView, false);
    const agentPopup = $.NSPopUpButton.alloc.initWithFramePullsDown($.NSMakeRect(140, sTop - 138, 180, 26), false);
    agentPopup.addItemWithTitle("Gemini (" + (agyPath ? "Installed" : "Not Found") + ")");
    agentPopup.addItemWithTitle("Codex (" + (codexPath ? "Installed" : "Not Found") + ")");
    if (config.agent === "codex") {
        agentPopup.selectItemAtIndex(1);
    } else {
        agentPopup.selectItemAtIndex(0);
    }
    settingsView.addSubview(agentPopup);

    createLabel(
        (config.agent === "codex" ? (codexPath || "Codex CLI not found") : (agyPath || "Gemini/Agy CLI not found")),
        330, sTop - 135, 255, 20, false, 10, settingsView, false
    );

    // Instructions
    createLabel("Instructions / Prompt Template:", 15, sTop - 165, 250, 20, true, 12, settingsView, false);
    const scrollInstr = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(15, sTop - 260, 570, 92));
    scrollInstr.setHasVerticalScroller(true);
    scrollInstr.setBorderType($.NSBezelBorder);

    const instrTextView = $.NSTextView.alloc.initWithFrame(scrollInstr.contentView.frame);
    instrTextView.setMinSize($.NSMakeSize(0.0, 92));
    instrTextView.setMaxSize($.NSMakeSize(10000.0, 10000.0));
    instrTextView.setVerticallyResizable(true);
    instrTextView.setHorizontallyResizable(false);
    instrTextView.setAutoresizingMask($.NSViewWidthSizable);
    instrTextView.setString(config.instructions || "");
    instrTextView.setFont($.NSFont.systemFontOfSize(12));
    scrollInstr.setDocumentView(instrTextView);
    settingsView.addSubview(scrollInstr);

    // Tools List
    createLabel("Tools Folders:", 15, sTop - 295, 120, 20, true, 12, settingsView, false);
    const toolsField = createTextField(config.tools.join("; "), 140, sTop - 295, 295, 22, settingsView);
    const btnAddTool = createButton("Add Folder…", 440, sTop - 297, 95, 26, settingsView);
    const btnClearTools = createButton("Clear", 540, sTop - 297, 45, 26, settingsView);

    // Skills List
    createLabel("Skills Folders:", 15, sTop - 328, 120, 20, true, 12, settingsView, false);
    const skillsField = createTextField(config.skills.join("; "), 140, sTop - 328, 295, 22, settingsView);
    const btnAddSkill = createButton("Add Folder…", 440, sTop - 330, 95, 26, settingsView);
    const btnClearSkills = createButton("Clear", 540, sTop - 330, 45, 26, settingsView);

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

    function checkWorkerHeartbeat() {
        const homeDir = ObjC.unwrap(homeField.stringValue).trim() || config.homeFolder;
        const currentInDir = fromDisplayPath(ObjC.unwrap(inputField.stringValue), homeDir);
        const currentOutDir = fromDisplayPath(ObjC.unwrap(outputField.stringValue), homeDir);

        const inItems = listDir(currentInDir).filter(n => !n.startsWith(".") && !n.endsWith(".hamster_claim") && !n.endsWith(".tmp"));
        const outItems = listDir(currentOutDir).filter(n => !n.startsWith("."));

        setCenterText(inputCountLabel, "" + inItems.length, $.NSColor.systemBlueColor);
        setCenterText(outputCountLabel, "" + outItems.length, $.NSColor.systemGreenColor);

        setCenterText(inputPathDisplay, toDisplayPath(currentInDir, homeDir), $.NSColor.secondaryLabelColor);
        setCenterText(outputPathDisplay, toDisplayPath(currentOutDir, homeDir), $.NSColor.secondaryLabelColor);

        if (!isWorkerRunning) return;

        if (currentTask !== null) {
            if (!currentTask.isRunning) {
                const exitCode = currentTask.terminationStatus;
                const claimPath = activeClaimItem.claimPath;
                const origPath = activeClaimItem.origPath;
                const filename = activeClaimItem.filename;
                const stagingDir = hamsterDir + "/work/output_staging";
                const outDir = config.outputFolder;

                const stagingItems = listDir(stagingDir);
                let hasOutput = (stagingItems.length > 0);

                if (exitCode === 0 && hasOutput) {
                    for (let item of stagingItems) {
                        const src = stagingDir + "/" + item;
                        const dest = outDir + "/" + item;
                        movePath(src, dest);
                    }
                    removePath(claimPath);

                    setCenterText(statusLabel, "Idle (Done " + filename + ")", $.NSColor.systemGreenColor);
                    setCenterText(itemLabel, "None", null);
                    setCenterText(detailsLabel, "Successfully finished: " + filename, null);
                } else {
                    if (fm.fileExistsAtPath(claimPath)) {
                        movePath(claimPath, origPath);
                    }
                    setCenterText(statusLabel, "Error: " + filename, $.NSColor.systemRedColor);
                    setCenterText(itemLabel, "Preserved input", null);
                    setCenterText(detailsLabel, "Agent failed (code " + exitCode + "). Input preserved. Check log.", null);
                }

                cleanDir(stagingDir);
                currentTask = null;
                activeClaimItem = null;
            }
            return;
        }

        const inDir = config.inputFolder;
        if (!inDir || !fm.fileExistsAtPath(inDir)) return;

        const items = listDir(inDir);
        if (items.length === 0) {
            setCenterText(itemLabel, "None (Inbox empty)", null);
            return;
        }

        let selectedItem = null;

        for (let name of items) {
            if (name.startsWith(".") || name.endsWith(".hamster_claim") || name.endsWith(".tmp")) {
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

        cleanDir(stagingDir);
        cleanDir(hamsterDir + "/work/claim");

        const moveSuccess = movePath(selectedItem.path, claimPath);
        if (!moveSuccess) {
            setCenterText(detailsLabel, "Could not claim item: " + filename, null);
            return;
        }

        activeClaimItem = {
            filename: filename,
            origPath: selectedItem.path,
            claimPath: claimPath
        };

        setCenterText(statusLabel, "Processing: " + filename, $.NSColor.systemOrangeColor);
        setCenterText(itemLabel, filename, null);
        setCenterText(detailsLabel, "Invoking " + config.agent.toUpperCase() + " agent...", null);

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
        if (config.agent === "codex" && codexPath) {
            let addDirArgs = "";
            config.tools.concat(config.skills).forEach(d => {
                if (d) addDirArgs += " --add-dir " + JSON.stringify(d);
            });
            agentCmd = codexPath + " exec " + JSON.stringify(prompt) + " --cd " + JSON.stringify(stagingDir) + addDirArgs + " > " + JSON.stringify(logFile) + " 2>&1";
        } else if (agyPath) {
            let addDirArgs = "";
            config.tools.concat(config.skills).forEach(d => {
                if (d) addDirArgs += " --add-dir " + JSON.stringify(d);
            });
            agentCmd = agyPath + " --print --dangerously-skip-permissions " + JSON.stringify(prompt) + addDirArgs + " > " + JSON.stringify(logFile) + " 2>&1";
        } else {
            agentCmd = "echo 'Processing without CLI...' > " + JSON.stringify(logFile) + "; cp -R " + JSON.stringify(claimPath) + " " + JSON.stringify(stagingDir + "/processed_" + filename);
        }

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
                    if (!isWorkerRunning) {
                        const homeDir = ObjC.unwrap(homeField.stringValue).trim() || config.homeFolder;
                        const inDir = fromDisplayPath(ObjC.unwrap(inputField.stringValue), homeDir);
                        const outDir = fromDisplayPath(ObjC.unwrap(outputField.stringValue), homeDir);

                        if (!inDir) {
                            setCenterText(detailsLabel, "⚠️ Missing Input Folder.", null);
                            return;
                        }
                        if (!outDir) {
                            setCenterText(detailsLabel, "⚠️ Missing Output Folder.", null);
                            return;
                        }

                        if (homeDir) makeDir(homeDir);
                        makeDir(inDir);
                        makeDir(outDir);

                        config.homeFolder = homeDir;
                        config.inputFolder = inDir;
                        config.outputFolder = outDir;
                        config.instructions = ObjC.unwrap(instrTextView.string);
                        config.agent = (agentPopup.indexOfSelectedItem === 1 ? "codex" : "gemini");
                        saveConfig();

                        isWorkerRunning = true;
                        btnStartStop.setTitle("⏹ Stop Hamster");
                        setCenterText(statusLabel, "Idle (Watching)", $.NSColor.systemGreenColor);
                        setCenterText(detailsLabel, "Watching inbox for items.", null);
                    } else {
                        isWorkerRunning = false;
                        btnStartStop.setTitle("▶ Start Hamster");
                        setCenterText(statusLabel, "Stopped", $.NSColor.secondaryLabelColor);
                        setCenterText(detailsLabel, "Worker stopped by user.", null);
                    }
                }
            },
            "onSave:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    config.homeFolder = ObjC.unwrap(homeField.stringValue).trim() || config.homeFolder;
                    config.inputFolder = fromDisplayPath(ObjC.unwrap(inputField.stringValue), config.homeFolder);
                    config.outputFolder = fromDisplayPath(ObjC.unwrap(outputField.stringValue), config.homeFolder);
                    config.instructions = ObjC.unwrap(instrTextView.string);
                    config.agent = (agentPopup.indexOfSelectedItem === 1 ? "codex" : "gemini");
                    saveConfig();
                    settingsFeedbackLabel.setStringValue("Saved at " + new Date().toLocaleTimeString());
                }
            },
            "onCreateHamster:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const currentDir = scriptPath.substring(0, scriptPath.lastIndexOf("/"));
                    const newId = "hamster-" + (Math.random().toString(36).substring(2, 10));
                    const destPath = currentDir + "/" + newId + ".command";

                    const ownCode = $.NSString.stringWithContentsOfFileEncodingError(scriptPath, $.NSUTF8StringEncoding, $());
                    let codeStr = ObjC.unwrap(ownCode);
                    codeStr = codeStr.replace(/HAMSTER_ID="[^"]*"/, 'HAMSTER_ID="' + newId + '"');

                    const nsCode = $.NSString.stringWithString(codeStr);
                    nsCode.writeToFileAtomicallyEncodingError(destPath, true, $.NSUTF8StringEncoding, $());

                    const task = $.NSTask.alloc.init;
                    task.setLaunchPath("/bin/chmod");
                    task.setArguments($([ "+x", destPath ]));
                    task.launch;
                    task.waitUntilExit;

                    const newHamsterDir = hamsterDir.replace(hamsterId, newId);
                    makeDir(newHamsterDir + "/work/claim");
                    makeDir(newHamsterDir + "/work/output_staging");

                    const newName = "Hamster " + newId.replace("hamster-", "");
                    const newSafeName = newName.replace(/\s+/g, "_");
                    const newHome = userHome + "/Hamsters/" + newSafeName;
                    const newInbox = newHome + "/inbox";
                    const newOutbox = newHome + "/outbox";

                    makeDir(newHome);
                    makeDir(newInbox);
                    makeDir(newOutbox);

                    const newConfig = Object.assign({}, config, {
                        name: newName,
                        homeFolder: newHome,
                        inputFolder: newInbox,
                        outputFolder: newOutbox
                    });

                    const newConfigStr = $.NSString.stringWithString(JSON.stringify(newConfig, null, 2));
                    newConfigStr.writeToFileAtomicallyEncodingError(
                        newHamsterDir + "/config.json", true, $.NSUTF8StringEncoding, $()
                    );
                    const newLocStr = $.NSString.stringWithString(destPath);
                    newLocStr.writeToFileAtomicallyEncodingError(
                        newHamsterDir + "/location.txt", true, $.NSUTF8StringEncoding, $()
                    );

                    $.NSWorkspace.sharedWorkspace.openFile(destPath);

                    setCenterText(detailsLabel, "Bred: " + newId + ".command", null);
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
                    } else {
                        setCenterText(detailsLabel, "No log file generated yet.", null);
                    }
                }
            },
            "onTimerTick:": {
                types: ["void", ["id"]],
                implementation: function(timer) {
                    checkWorkerHeartbeat();
                }
            },
            "applicationShouldHandleReopen:hasVisibleWindows:": {
                types: ["bool", ["id", "bool"]],
                implementation: function(sender, flag) {
                    win.makeKeyAndOrderFront(null);
                    win.orderFrontRegardless;
                    app.activateIgnoringOtherApps(true);
                    return true;
                }
            },
            "windowWillClose:": {
                types: ["void", ["id"]],
                implementation: function(notification) {
                    if (currentTask && currentTask.isRunning) {
                        currentTask.terminate;
                    }
                    if (activeClaimItem && fm.fileExistsAtPath(activeClaimItem.claimPath)) {
                        movePath(activeClaimItem.claimPath, activeClaimItem.origPath);
                    }
                    removePath(pidFile);
                    app.terminate(null);
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

    // Show window and bring to front
    win.makeKeyAndOrderFront(null);
    win.orderFrontRegardless;
    app.activateIgnoringOtherApps(true);

    // Start Native Cocoa Run Loop
    app.run;
}
EOF
