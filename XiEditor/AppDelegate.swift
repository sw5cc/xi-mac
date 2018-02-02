// Copyright 2016 Google Inc. All rights reserved.
//
// Licensed under the Apache License, Version 2.0 (the "License");
// you may not use this file except in compliance with the License.
// You may obtain a copy of the License at
//
//     http://www.apache.org/licenses/LICENSE-2.0
//
// Unless required by applicable law or agreed to in writing, software
// distributed under the License is distributed on an "AS IS" BASIS,
// WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
// See the License for the specific language governing permissions and
// limitations under the License.

import Cocoa

let USER_DEFAULTS_THEME_KEY = "io.xi-editor.settings.theme"
let USER_DEFAULTS_NEW_WINDOW_FRAME = "io.xi-editor.settings.preferredWindowFrame"
let XI_CONFIG_DIR = "XI_CONFIG_DIR";
let PREFERENCES_FILE_NAME = "preferences.xiconfig"

class BoolToControlStateValueTransformer: ValueTransformer {
    override class func transformedValueClass() -> AnyClass {
        return NSNumber.self
    }
    
    override class func allowsReverseTransformation() -> Bool {
        return false
    }
    
    override func transformedValue(_ value: Any?) -> Any? {
        guard let boolValue = value as? Bool else { return NSControl.StateValue.mixed }
        return boolValue ? NSControl.StateValue.on : NSControl.StateValue.off
    }
    
    override func reverseTransformedValue(_ value: Any?) -> Any? {
        guard let type = value as? NSControl.StateValue else { return false }
        return type == NSControl.StateValue.on ? true : false
    }
}

extension NSValueTransformerName {
    static let boolToControlStateValueTransformerName = NSValueTransformerName(rawValue: "BoolToControlStateValueTransformer")
}

@NSApplicationMain
class AppDelegate: NSObject, NSApplicationDelegate, XiClient {

    var dispatcher: Dispatcher?
    var documentController: XiDocumentController!

    // This is set to 'InconsolataGo' in the user preferences; this value is a fallback.
    let fallbackFont = CTFontCreateWithName(("Menlo" as CFString?)!, 14, nil)

    lazy fileprivate var _textMetrics = TextDrawingMetrics(font: self.fallbackFont,
                                                           textColor: self.theme.foreground)

    @objc dynamic var collectTracingSamplesEnabled : Bool {
        get {
            return Trace.shared.isEnabled()
        }
        set {
            Trace.shared.setEnabled(newValue)
            updateRpcTracingConfig(newValue)
        }
    }

    var textMetrics: TextDrawingMetrics {
        get {
            return _textMetrics
        }
        set {
            _textMetrics = newValue
            styleMap.locked().updateFont(to: newValue.font)
            self.updateAllViews()
        }
    }

    lazy var styleMap: StyleMap = StyleMap(font: self.fallbackFont)

    lazy var defaultConfigDirectory: URL = {
        let applicationDirectory = FileManager.default.urls(
            for: .applicationSupportDirectory,
            in: .userDomainMask)
            .first!
            .appendingPathComponent("XiEditor")

        // create application support directory and copy preferences file on first run
        if !FileManager.default.fileExists(atPath: applicationDirectory.path) {
            do {

                try FileManager.default.createDirectory(at: applicationDirectory,
                                                        withIntermediateDirectories: true,
                                                        attributes: nil)
                let preferencesPath = applicationDirectory.appendingPathComponent(PREFERENCES_FILE_NAME)
                let defaultConfigPath = Bundle.main.url(forResource: "client_example", withExtension: "toml")
                try FileManager.default.copyItem(at: defaultConfigPath!, to: preferencesPath)


            } catch let err  {
                fatalError("Failed to create application support directory \(applicationDirectory.path). \(err)")
            }
        } 
        return applicationDirectory
    }()

    var theme = Theme.defaultTheme() {
        didSet {
            self.textMetrics = TextDrawingMetrics(font: textMetrics.font,
                                                  textColor: theme.foreground)
        }
    }
    
    override init() {
        ValueTransformer.setValueTransformer(
            BoolToControlStateValueTransformer(),
            forName: .boolToControlStateValueTransformerName)
    }

    func applicationWillFinishLaunching(_ aNotification: Notification) {
        let collectSamplesOnBoot = true
        
        self.collectTracingSamplesEnabled = collectSamplesOnBoot
        Trace.shared.trace("appWillLaunch", .main, .begin)

        guard let corePath = Bundle.main.path(forResource: "xi-core", ofType: ""),
        let bundledPluginPath = Bundle.main.path(forResource: "plugins", ofType: "")
            else { fatalError("Xi bundle missing expected resouces") }

        let dispatcher: Dispatcher = {
            let coreConnection = CoreConnection(path: corePath)
            coreConnection.client = self
            return Dispatcher(coreConnection: coreConnection)
        }()

        self.dispatcher = dispatcher
        updateRpcTracingConfig(collectSamplesOnBoot)

        let params = ["client_extras_dir": bundledPluginPath,
                           "config_dir": getUserConfigDirectory()]
        dispatcher.coreConnection.sendRpcAsync("client_started",
                                               params: params)
        
        // fallback values used by NSUserDefaults
        let defaultDefaults: [String: Any] = [
            USER_DEFAULTS_THEME_KEY: "InspiredGitHub",
            USER_DEFAULTS_NEW_WINDOW_FRAME: NSStringFromRect(NSRect(x: 200, y: 200, width: 600, height: 600))
        ]
        UserDefaults.standard.register(defaults: defaultDefaults)

        // For legacy reasons, we currently treat themes distinctly than other preferences.
        let preferredTheme = UserDefaults.standard.string(forKey: USER_DEFAULTS_THEME_KEY)!
        let req = Events.SetTheme(themeName: preferredTheme)
        dispatcher.coreConnection.sendRpcAsync(req.method, params: req.params!)
        Trace.shared.trace("appWillLaunch", .main, .end)
        documentController = XiDocumentController()
    }

    // MARK: - XiClient protocol

    func update(viewIdentifier: String, update: [String: AnyObject], rev: UInt64?) {
        let document = documentForViewIdentifier(viewIdentifier: viewIdentifier)
        if document == nil { print("document missing for view id \(viewIdentifier)") }
        document?.updateAsync(update: update)
    }

    func scroll(viewIdentifier: String, line: Int, column: Int) {
        let document = documentForViewIdentifier(viewIdentifier: viewIdentifier)
        DispatchQueue.main.async {
            document?.editViewController?.scrollTo(line, column)
        }
    }

    func defineStyle(style: [String: AnyObject]) {
        // defineStyle, like update, is handled on the read thread.
        styleMap.locked().defStyle(json: style)
    }

    func themeChanged(name: String, theme: Theme) {
        DispatchQueue.main.async { [weak self] in
            UserDefaults.standard.set(name, forKey: USER_DEFAULTS_THEME_KEY)
            self?.theme = theme
            for doc in NSApplication.shared.orderedDocuments {
                guard let doc = doc as? Document else { continue }
                doc.editViewController?.themeChanged(name)
            }
        }
    }

    func availableThemes(themes: [String]) {
        DispatchQueue.main.async {
            for doc in NSApplication.shared.orderedDocuments {
                guard let doc = doc as? Document else { continue }
                doc.editViewController?.availableThemesChanged(themes)
            }
        }
    }

    func pluginStarted(viewIdentifier: String, pluginName: String) {
        let document = documentForViewIdentifier(viewIdentifier: viewIdentifier)
        DispatchQueue.main.async {
            document?.editViewController?.pluginStarted(pluginName)
        }
    }

    func pluginStopped(viewIdentifier: String, pluginName: String) {
        let document = documentForViewIdentifier(viewIdentifier: viewIdentifier)
        DispatchQueue.main.async {
            document?.editViewController?.pluginStopped(pluginName)
        }
    }

    func availablePlugins(viewIdentifier: String, plugins: [[String: AnyObject]]) {
        let document = documentForViewIdentifier(viewIdentifier: viewIdentifier)
        var available: [String: Bool] = [:]
        for item in plugins {
            available[item["name"] as! String] = item["running"] as? Bool
        }
        DispatchQueue.main.async {
            document?.editViewController?.availablePlugins = available
        }
    }

    func updateCommands(viewIdentifier: String, plugin: String, commands: [Command]) {
        let document = documentForViewIdentifier(viewIdentifier: viewIdentifier)
        DispatchQueue.main.async {
            document?.editViewController?.updateCommands(plugin: plugin,
                                                         commands: commands)
        }
    }

    func alert(text: String) {
        DispatchQueue.main.async {
            let alert =  NSAlert.init()
            alert.alertStyle = .informational
            alert.messageText = text
            alert.runModal()
        }
    }

    func configChanged(viewIdentifier: ViewIdentifier, changes: [String : AnyObject]) {
        let document = documentForViewIdentifier(viewIdentifier: viewIdentifier)
        DispatchQueue.main.async {
            document?.editViewController?.configChanged(changes: changes)
        }
    }

    //MARK: - top-level interactions
    @IBAction func openPreferences(_ sender: NSMenuItem) {
        let delegate = (NSApplication.shared.delegate as? AppDelegate)
        if let preferencesPath = delegate?.defaultConfigDirectory.appendingPathComponent(PREFERENCES_FILE_NAME) {
            NSDocumentController.shared.openDocument(
                withContentsOf: preferencesPath,
                display: true,
                completionHandler: { (document, alreadyOpen, error) in
                    if let error = error {
                        print("error opening preferences \(error)")
                    }
            });
        }
    }

    //- MARK: - helpers

    /// returns the NSDocument corresponding to the given viewIdentifier
    private func documentForViewIdentifier(viewIdentifier: ViewIdentifier) -> Document? {
        return (NSDocumentController.shared as! XiDocumentController)
            .documentForViewIdentifier(viewIdentifier)
    }

    /// Redraws all open document views, as on a font or theme change.
    private func updateAllViews() {
        for doc in NSApplication.shared.orderedDocuments {
            guard let doc = doc as? Document else { continue }
            doc.editViewController?.redrawEverything()
        }
    }

    func handleFontChange(fontName: String?, fontSize: CGFloat?) {
        guard (textMetrics.font.fontName != fontName && textMetrics.font.familyName != fontName)
            || textMetrics.font.pointSize != fontSize else { return }

        if let newFont = NSFont(name: fontName ?? textMetrics.font.fontName,
                                size: fontSize ?? textMetrics.font.pointSize) {
            textMetrics = TextDrawingMetrics(font: newFont, textColor: theme.foreground)
        }
    }

    func getUserConfigDirectory() -> String {
        if let configDir = ProcessInfo.processInfo.environment[XI_CONFIG_DIR] {
            return URL(fileURLWithPath: configDir).path
        } else {
            return defaultConfigDirectory.path
        }
    }

    // This is test code for the new text plane and will be deleted when it's wired up to the actual EditView.
    var testWindow: NSWindow?
    @IBAction func textPlaneTest(_ sender: AnyObject) {
        let frame = NSRect(x: 100, y: 100, width: 800, height: 600)
        testWindow = NSWindow(contentRect: frame, styleMask: [.titled, .closable, .resizable, .miniaturizable], backing: .buffered, defer: false)
        testWindow?.makeKeyAndOrderFront(self)
        testWindow?.contentView = TextPlaneDemo(frame: frame)
    }
    
    func updateRpcTracingConfig(_ enabled: Bool) {
        guard let dispatcher = self.dispatcher else { return }
        Events.TracingConfig(enabled: enabled).dispatch(dispatcher)
    }

    @IBAction func writeTrace(_ sender: AnyObject) {
        let pid = getpid()

        let saveDialog = NSSavePanel.init()
        saveDialog.nameFieldStringValue = "xi-trace-\(pid)"
        if #available(OSX 10.12, *) {
            saveDialog.directoryURL = FileManager.default.temporaryDirectory
        }
        saveDialog.begin { (response) in
            guard response == .OK else { return }
            if !(saveDialog.url?.isFileURL ?? false) {
                return
            }
            guard let destinationUrl = saveDialog.url?.absoluteString else { return }
            let schemeEndIdx = destinationUrl.index(destinationUrl.startIndex, offsetBy: 7)
            let destination = String(destinationUrl.suffix(from: schemeEndIdx))

            // TODO: have UI start showing that the trace is saving & then clear
            // that in a callback (or make it synchronous on a global dispatch
            // queue).
            Events.SaveTrace(destination: destination, frontendSamples: Trace.shared.snapshot()).dispatch(self.dispatcher!)
        }
    }
}
