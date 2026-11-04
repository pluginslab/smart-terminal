// Chromium's subprocesses (renderer, GPU, plugin, alerts) run this. bundle.sh copies
// it into the five "SmartTerminal Helper (…).app" bundles Chromium expects; it loads
// the framework, becomes whatever process Chromium asked for, and exits.
import CefKit

CefRuntime.helperMain()
