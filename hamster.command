#!/bin/bash
# ==============================================================================
# 🐹 HAMSTER - Single-File macOS Autonomous Worker Prototype
# ==============================================================================
# Hard Constraints:
# - Entire app contained in this single .command file.
# - No external packages or compilers; uses macOS native zsh/bash, JXA & AppKit.
# - Persistent independent state per Hamster under ~/Library/Application Support/Hamsters/<HAMSTER_ID>/
# - Hamster Home base directory with clean relative paths for Inbox and Outbox.
# - Safe claiming, processing, and atomic output finalization.
# - Native Cocoa event loop (app.run) for instantaneous UI responsiveness.
# - Full Dock, Cmd+Tab, and Menu Bar integration.
# ==============================================================================

# Ensure common CLI paths are available even when launched from Finder
export PATH="/usr/local/bin:/opt/homebrew/bin:/opt/homebrew/sbin:$HOME/.local/bin:$HOME/.gemini/bin:$HOME/.codex/bin:$HOME/bin:$PATH"

# Persistent Unique Hamster Identity placeholder (auto-populated on first run or clone)
HAMSTER_ID="hamster-0a215825"

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

    // Relative & Absolute Path Display Helpers
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

    // Ensure default directories exist
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

    // Menu Bar Setup (Standard Mac Shortcuts: Cmd+Q, Cmd+C, Cmd+V, Cmd+A, Cmd+Z)
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

    const winWidth = 640;
    const winHeight = 760;
    const winRect = $.NSMakeRect(200, 200, winWidth, winHeight);
    const styleMask = $.NSWindowStyleMaskTitled | $.NSWindowStyleMaskClosable | $.NSWindowStyleMaskMiniaturizable;
    const win = $.NSWindow.alloc.initWithContentRectStyleMaskBackingDefer(winRect, styleMask, $.NSBackingStoreBuffered, false);

    win.setTitle("🐹 " + config.name + " (" + hamsterId + ")");
    win.setReleasedWhenClosed(false);
    win.center;

    const contentView = win.contentView;

    // Helper UI creators
    function createLabel(text, x, y, w, h, isBold, size) {
        const label = $.NSTextField.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
        label.setStringValue(text);
        label.setBezeled(false);
        label.setDrawsBackground(false);
        label.setEditable(false);
        label.setSelectable(true);
        if (isBold) {
            label.setFont($.NSFont.boldSystemFontOfSize(size || 13));
        } else if (size) {
            label.setFont($.NSFont.systemFontOfSize(size));
        }
        contentView.addSubview(label);
        return label;
    }

    function createTextField(text, x, y, w, h) {
        const tf = $.NSTextField.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
        tf.setStringValue(text || "");
        contentView.addSubview(tf);
        return tf;
    }

    function createButton(title, x, y, w, h) {
        const btn = $.NSButton.alloc.initWithFrame($.NSMakeRect(x, y, w, h));
        btn.setTitle(title);
        btn.setBezelStyle($.NSBezelStyleRounded);
        contentView.addSubview(btn);
        return btn;
    }

    // Top Header
    createLabel("🐹 " + config.name, 20, winHeight - 40, 300, 25, true, 16);
    createLabel("ID: " + hamsterId, winWidth - 220, winHeight - 38, 200, 20, false, 11);

    // Name Field
    createLabel("Hamster Name:", 20, winHeight - 75, 120, 20, true);
    const nameField = createTextField(config.name, 140, winHeight - 75, 475, 22);

    // Hamster Home Field + Choose + Open
    createLabel("Hamster Home:", 20, winHeight - 110, 120, 20, true);
    const homeField = createTextField(config.homeFolder, 140, winHeight - 110, 320, 22);
    const btnChooseHome = createButton("Choose…", 465, winHeight - 112, 80, 26);
    const btnOpenHome = createButton("📂 Open", 548, winHeight - 112, 68, 26);

    // Input Folder (Inbox) Field + Choose + Open (shows relative path inside home)
    createLabel("Input (Inbox):", 20, winHeight - 145, 120, 20, true);
    const inputField = createTextField(toDisplayPath(config.inputFolder, config.homeFolder), 140, winHeight - 145, 320, 22);
    const btnChooseInput = createButton("Choose…", 465, winHeight - 147, 80, 26);
    const btnOpenInput = createButton("📂 Open", 548, winHeight - 147, 68, 26);

    // Output Folder (Outbox) Field + Choose + Open (shows relative path inside home)
    createLabel("Output (Outbox):", 20, winHeight - 180, 120, 20, true);
    const outputField = createTextField(toDisplayPath(config.outputFolder, config.homeFolder), 140, winHeight - 180, 320, 22);
    const btnChooseOutput = createButton("Choose…", 465, winHeight - 182, 80, 26);
    const btnOpenOutput = createButton("📂 Open", 548, winHeight - 182, 68, 26);

    // Agent Selector
    createLabel("AI Backend:", 20, winHeight - 215, 120, 20, true);
    const agentPopup = $.NSPopUpButton.alloc.initWithFramePullsDown($.NSMakeRect(140, winHeight - 218, 200, 26), false);
    agentPopup.addItemWithTitle("Gemini (" + (agyPath ? "Installed" : "Not Found") + ")");
    agentPopup.addItemWithTitle("Codex (" + (codexPath ? "Installed" : "Not Found") + ")");
    if (config.agent === "codex") {
        agentPopup.selectItemAtIndex(1);
    } else {
        agentPopup.selectItemAtIndex(0);
    }
    contentView.addSubview(agentPopup);

    createLabel(
        (config.agent === "codex" ? (codexPath || "Codex CLI not found") : (agyPath || "Gemini/Agy CLI not found")),
        350, winHeight - 215, 265, 20, false, 10
    );

    // Instructions
    createLabel("Instructions / Prompt Template:", 20, winHeight - 250, 250, 20, true);
    const scrollInstr = $.NSScrollView.alloc.initWithFrame($.NSMakeRect(20, winHeight - 370, 595, 115));
    scrollInstr.setHasVerticalScroller(true);
    scrollInstr.setBorderType($.NSBezelBorder);

    const instrTextView = $.NSTextView.alloc.initWithFrame(scrollInstr.contentView.frame);
    instrTextView.setMinSize($.NSMakeSize(0.0, 115));
    instrTextView.setMaxSize($.NSMakeSize(10000.0, 10000.0));
    instrTextView.setVerticallyResizable(true);
    instrTextView.setHorizontallyResizable(false);
    instrTextView.setAutoresizingMask($.NSViewWidthSizable);
    instrTextView.setString(config.instructions || "");
    instrTextView.setFont($.NSFont.systemFontOfSize(12));
    scrollInstr.setDocumentView(instrTextView);
    contentView.addSubview(scrollInstr);

    // Tools List
    createLabel("Tools Folders:", 20, winHeight - 400, 120, 20, true);
    const toolsField = createTextField(config.tools.join("; "), 140, winHeight - 400, 335, 22);
    const btnAddTool = createButton("Add Folder…", 480, winHeight - 402, 100, 26);
    const btnClearTools = createButton("Clear", 580, winHeight - 402, 45, 26);

    // Skills List
    createLabel("Skills Folders:", 20, winHeight - 435, 120, 20, true);
    const skillsField = createTextField(config.skills.join("; "), 140, winHeight - 400, 335, 22);
    const btnAddSkill = createButton("Add Folder…", 480, winHeight - 437, 100, 26);
    const btnClearSkills = createButton("Clear", 580, winHeight - 437, 45, 26);

    // Divider / Box
    const box = $.NSBox.alloc.initWithFrame($.NSMakeRect(20, 150, 595, 140));
    box.setTitle("Runtime Status");
    box.setBoxType($.NSBoxPrimary);
    contentView.addSubview(box);

    const statusLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(15, 80, 560, 24));
    statusLabel.setStringValue("Status: Stopped");
    statusLabel.setBezeled(false);
    statusLabel.setDrawsBackground(false);
    statusLabel.setEditable(false);
    statusLabel.setFont($.NSFont.boldSystemFontOfSize(14));
    statusLabel.setTextColor($.NSColor.secondaryLabelColor);
    box.contentView.addSubview(statusLabel);

    const itemLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(15, 45, 560, 20));
    itemLabel.setStringValue("Current Item: None");
    itemLabel.setBezeled(false);
    itemLabel.setDrawsBackground(false);
    itemLabel.setEditable(false);
    itemLabel.setFont($.NSFont.systemFontOfSize(12));
    box.contentView.addSubview(itemLabel);

    const detailsLabel = $.NSTextField.alloc.initWithFrame($.NSMakeRect(15, 15, 560, 22));
    detailsLabel.setStringValue("Idle");
    detailsLabel.setBezeled(false);
    detailsLabel.setDrawsBackground(false);
    detailsLabel.setEditable(false);
    detailsLabel.setFont($.NSFont.systemFontOfSize(11));
    detailsLabel.setTextColor($.NSColor.secondaryLabelColor);
    box.contentView.addSubview(detailsLabel);

    // Bottom Action Buttons
    const btnStartStop = createButton("▶ Start Hamster", 20, 85, 160, 36);
    btnStartStop.setFont($.NSFont.boldSystemFontOfSize(13));

    const btnSave = createButton("💾 Save Config", 190, 85, 120, 36);
    const btnCreateHamster = createButton("✨ Create Hamster…", 445, 85, 170, 36);

    const btnOpenStorage = createButton("⚙️ State Folder", 20, 25, 130, 24);
    const btnViewLog = createButton("📄 Last Log", 160, 25, 100, 24);

    // -------------------------------------------------------------------------
    // Worker State Engine
    // -------------------------------------------------------------------------
    let isWorkerRunning = false;
    let currentTask = null;
    let activeClaimItem = null;
    let stabilityTracker = {};

    function checkWorkerHeartbeat() {
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

                    statusLabel.setStringValue("Status: Idle (Completed " + filename + ")");
                    statusLabel.setTextColor($.NSColor.systemGreenColor);
                    itemLabel.setStringValue("Current Item: None");
                    detailsLabel.setStringValue("Successfully delivered output to " + outDir);
                } else {
                    if (fm.fileExistsAtPath(claimPath)) {
                        movePath(claimPath, origPath);
                    }
                    statusLabel.setStringValue("Status: Error on " + filename);
                    statusLabel.setTextColor($.NSColor.systemRedColor);
                    itemLabel.setStringValue("Current Item: None (Preserved input)");
                    detailsLabel.setStringValue("Agent failed (code " + exitCode + "). Input preserved. Check log.");
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
            itemLabel.setStringValue("Current Item: None (Folder empty)");
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
            detailsLabel.setStringValue("Could not claim item: " + filename);
            return;
        }

        activeClaimItem = {
            filename: filename,
            origPath: selectedItem.path,
            claimPath: claimPath
        };

        statusLabel.setStringValue("Status: Processing: " + filename);
        statusLabel.setTextColor($.NSColor.systemOrangeColor);
        itemLabel.setStringValue("Current Item: " + filename);
        detailsLabel.setStringValue("Invoking " + config.agent.toUpperCase() + " agent...");

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
        name: "HamsterCoordinatorV5",
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

                        // Re-resolve inbox & outbox relative to new home
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
                            detailsLabel.setStringValue("⚠️ Please specify a valid Input Folder.");
                            return;
                        }
                        if (!outDir) {
                            detailsLabel.setStringValue("⚠️ Please specify a valid Output Folder.");
                            return;
                        }

                        if (homeDir) makeDir(homeDir);
                        makeDir(inDir);
                        makeDir(outDir);

                        config.name = ObjC.unwrap(nameField.stringValue);
                        config.homeFolder = homeDir;
                        config.inputFolder = inDir;
                        config.outputFolder = outDir;
                        config.instructions = ObjC.unwrap(instrTextView.string);
                        config.agent = (agentPopup.indexOfSelectedItem === 1 ? "codex" : "gemini");
                        saveConfig();

                        isWorkerRunning = true;
                        btnStartStop.setTitle("⏹ Stop Hamster");
                        statusLabel.setStringValue("Status: Idle (Watching Input Folder)");
                        statusLabel.setTextColor($.NSColor.systemGreenColor);
                        detailsLabel.setStringValue("Watching: " + inDir);
                    } else {
                        isWorkerRunning = false;
                        btnStartStop.setTitle("▶ Start Hamster");
                        statusLabel.setStringValue("Status: Stopped");
                        statusLabel.setTextColor($.NSColor.secondaryLabelColor);
                        detailsLabel.setStringValue("Worker stopped by user.");
                    }
                }
            },
            "onSave:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    config.name = ObjC.unwrap(nameField.stringValue);
                    config.homeFolder = ObjC.unwrap(homeField.stringValue).trim() || config.homeFolder;
                    config.inputFolder = fromDisplayPath(ObjC.unwrap(inputField.stringValue), config.homeFolder);
                    config.outputFolder = fromDisplayPath(ObjC.unwrap(outputField.stringValue), config.homeFolder);
                    config.instructions = ObjC.unwrap(instrTextView.string);
                    config.agent = (agentPopup.indexOfSelectedItem === 1 ? "codex" : "gemini");
                    saveConfig();
                    win.setTitle("🐹 " + config.name + " (" + hamsterId + ")");
                    detailsLabel.setStringValue("Configuration saved successfully.");
                }
            },
            "onCreateHamster:": {
                types: ["void", ["id"]],
                implementation: function(sender) {
                    const savePanel = $.NSSavePanel.savePanel;
                    savePanel.setTitle("Create New Hamster");
                    savePanel.setMessage("Choose location and name for the new Hamster worker");
                    savePanel.setNameFieldStringValue("Hamster-" + (Math.random().toString(36).substring(2, 6)) + ".command");
                    savePanel.setAllowedFileTypes($([ "command" ]));

                    if (savePanel.runModal == $.NSModalResponseOK) {
                        const destPath = ObjC.unwrap(savePanel.URL.path);
                        const newId = "hamster-" + (Math.random().toString(36).substring(2, 10));

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

                        // Automatically launch the new Hamster window
                        $.NSWorkspace.sharedWorkspace.openFile(destPath);

                        detailsLabel.setStringValue("Created and launched: " + destPath);
                    }
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
                        detailsLabel.setStringValue("No log file generated yet.");
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

    const coordinator = $.HamsterCoordinatorV5.alloc.init;
    app.setDelegate(coordinator);
    win.setDelegate(coordinator);

    // Bind Button Targets and Actions directly
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

    btnStartStop.setTarget(coordinator);
    btnStartStop.setAction("onStartStop:");

    btnSave.setTarget(coordinator);
    btnSave.setAction("onSave:");

    btnCreateHamster.setTarget(coordinator);
    btnCreateHamster.setAction("onCreateHamster:");

    btnOpenStorage.setTarget(coordinator);
    btnOpenStorage.setAction("onOpenStorage:");

    btnViewLog.setTarget(coordinator);
    btnViewLog.setAction("onViewLog:");

    // Start 0.5s RunLoop Timer for background worker
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
