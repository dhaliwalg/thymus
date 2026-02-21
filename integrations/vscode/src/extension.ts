import * as vscode from 'vscode';
import { execFile } from 'child_process';
import { existsSync } from 'fs';
import { join, dirname } from 'path';

interface ThymusViolation {
  file: string;
  line?: number;
  rule_id: string;
  rule_name?: string;
  severity: 'error' | 'warn' | 'info';
  message: string;
  import_path?: string;
}

let diagnosticCollection: vscode.DiagnosticCollection;
let statusBarItem: vscode.StatusBarItem;
let outputChannel: vscode.OutputChannel;
let thymusBinary: string | null = null;
let binaryWarningShown = false;
let debounceTimer: ReturnType<typeof setTimeout> | undefined;
let violationCount = 0;

export function activate(context: vscode.ExtensionContext): void {
  outputChannel = vscode.window.createOutputChannel('Thymus');
  diagnosticCollection = vscode.languages.createDiagnosticCollection('thymus');
  statusBarItem = vscode.window.createStatusBarItem(vscode.StatusBarAlignment.Left, 100);
  statusBarItem.command = 'thymus.scanWorkspace';

  context.subscriptions.push(diagnosticCollection, statusBarItem, outputChannel);

  thymusBinary = findThymusBinary();
  if (!thymusBinary) {
    if (!binaryWarningShown) {
      vscode.window.showInformationMessage(
        "Thymus binary not found. Run 'thymus init' or set thymus.binaryPath in settings."
      );
      binaryWarningShown = true;
    }
    return;
  }

  updateStatusBar();
  statusBarItem.show();

  // Check on save
  context.subscriptions.push(
    vscode.workspace.onDidSaveTextDocument((doc) => {
      const config = vscode.workspace.getConfiguration('thymus');
      if (config.get<boolean>('enable') && config.get<boolean>('checkOnSave')) {
        checkFile(doc.uri);
      }
    })
  );

  // Check on type (debounced)
  context.subscriptions.push(
    vscode.workspace.onDidChangeTextDocument((event) => {
      const config = vscode.workspace.getConfiguration('thymus');
      if (config.get<boolean>('enable') && config.get<boolean>('checkOnType')) {
        if (debounceTimer) {
          clearTimeout(debounceTimer);
        }
        debounceTimer = setTimeout(() => {
          checkFile(event.document.uri);
        }, 500);
      }
    })
  );

  // Clear diagnostics on close
  context.subscriptions.push(
    vscode.workspace.onDidCloseTextDocument((doc) => {
      diagnosticCollection.delete(doc.uri);
    })
  );

  // Scan workspace command
  context.subscriptions.push(
    vscode.commands.registerCommand('thymus.scanWorkspace', () => {
      scanWorkspace();
    })
  );

  // Show health command
  context.subscriptions.push(
    vscode.commands.registerCommand('thymus.showHealth', () => {
      if (thymusBinary) {
        const workspaceRoot = getWorkspaceRoot();
        if (workspaceRoot) {
          const reportPath = join(workspaceRoot, '.thymus', 'report.html');
          if (existsSync(reportPath)) {
            vscode.env.openExternal(vscode.Uri.file(reportPath));
          } else {
            vscode.window.showInformationMessage('No health report found. Run a scan first.');
          }
        }
      }
    })
  );

  // Re-detect binary on config change
  context.subscriptions.push(
    vscode.workspace.onDidChangeConfiguration((e) => {
      if (e.affectsConfiguration('thymus.binaryPath')) {
        thymusBinary = findThymusBinary();
      }
    })
  );
}

function findThymusBinary(): string | null {
  const config = vscode.workspace.getConfiguration('thymus');
  const configPath = config.get<string>('binaryPath');
  if (configPath && existsSync(configPath)) {
    return configPath;
  }

  // Search from workspace root upward
  let dir = getWorkspaceRoot();
  while (dir && dir !== '/') {
    const candidate = join(dir, 'bin', 'thymus-check');
    if (existsSync(candidate)) {
      return candidate;
    }
    dir = dirname(dir);
  }
  return null;
}

function getWorkspaceRoot(): string | undefined {
  return vscode.workspace.workspaceFolders?.[0]?.uri.fsPath;
}

function checkFile(uri: vscode.Uri): void {
  if (!thymusBinary) { return; }

  const filePath = uri.fsPath;

  // Skip excluded directories
  const excludedDirs = ['.thymus', 'node_modules', '.git', 'dist', 'coverage'];
  if (excludedDirs.some(dir => filePath.includes(`/${dir}/`) || filePath.includes(`\\${dir}\\`))) {
    return;
  }

  const workspaceRoot = getWorkspaceRoot();
  if (!workspaceRoot) { return; }

  const relativePath = filePath.startsWith(workspaceRoot)
    ? filePath.slice(workspaceRoot.length + 1)
    : filePath;

  execFile(thymusBinary, [relativePath, '--format', 'json'], {
    cwd: workspaceRoot,
    timeout: 5000,
  }, (error: Error | null, stdout: string, stderr: string) => {
    if (stderr) {
      outputChannel.appendLine(`[stderr] ${stderr}`);
    }

    // If the process failed and there's no JSON output, clear diagnostics
    if (error && !stdout.trim()) {
      diagnosticCollection.delete(uri);
      return;
    }

    let violations: ThymusViolation[];
    try {
      violations = JSON.parse(stdout || '[]');
    } catch {
      outputChannel.appendLine(`[parse error] ${stdout}`);
      diagnosticCollection.delete(uri);
      return;
    }

    const diagnostics: vscode.Diagnostic[] = violations.map((v) => {
      const line = (v.line && v.line > 0) ? v.line - 1 : 0;
      const range = new vscode.Range(line, 0, line, Number.MAX_SAFE_INTEGER);
      const severity = mapSeverity(v.severity);
      const diagnostic = new vscode.Diagnostic(range, v.message, severity);
      diagnostic.source = `thymus (${v.rule_id})`;
      diagnostic.code = v.rule_id;
      return diagnostic;
    });

    diagnosticCollection.set(uri, diagnostics);

    // Update global count
    violationCount = 0;
    diagnosticCollection.forEach((_, diags) => {
      violationCount += diags.length;
    });
    updateStatusBar();
  });
}

function scanWorkspace(): void {
  if (!thymusBinary) {
    vscode.window.showWarningMessage('Thymus binary not found.');
    return;
  }

  const workspaceRoot = getWorkspaceRoot();
  if (!workspaceRoot) { return; }

  // thymus-check is for single files; for workspace scan, use thymus-scan
  const scanBinary = thymusBinary.replace('thymus-check', 'thymus-scan');

  vscode.window.withProgress({
    location: vscode.ProgressLocation.Notification,
    title: 'Thymus: Scanning workspace...',
    cancellable: false,
  }, () => {
    return new Promise<void>((resolve) => {
      execFile(scanBinary, ['--format', 'json'], {
        cwd: workspaceRoot,
        timeout: 30000,
      }, (error: Error | null, stdout: string, stderr: string) => {
        if (stderr) {
          outputChannel.appendLine(`[scan stderr] ${stderr}`);
        }

        let violations: ThymusViolation[];
        try {
          violations = JSON.parse(stdout || '[]');
        } catch {
          outputChannel.appendLine(`[scan parse error] ${stdout}`);
          resolve();
          return;
        }

        // Clear all existing diagnostics
        diagnosticCollection.clear();

        // Group violations by file
        const byFile = new Map<string, ThymusViolation[]>();
        for (const v of violations) {
          const absPath = join(workspaceRoot, v.file);
          if (!byFile.has(absPath)) {
            byFile.set(absPath, []);
          }
          byFile.get(absPath)!.push(v);
        }

        // Set diagnostics per file
        for (const [absPath, fileViolations] of byFile) {
          const uri = vscode.Uri.file(absPath);
          const diagnostics = fileViolations.map((v) => {
            const line = (v.line && v.line > 0) ? v.line - 1 : 0;
            const range = new vscode.Range(line, 0, line, Number.MAX_SAFE_INTEGER);
            const diagnostic = new vscode.Diagnostic(range, v.message, mapSeverity(v.severity));
            diagnostic.source = `thymus (${v.rule_id})`;
            diagnostic.code = v.rule_id;
            return diagnostic;
          });
          diagnosticCollection.set(uri, diagnostics);
        }

        violationCount = violations.length;
        updateStatusBar();

        vscode.window.showInformationMessage(
          `Thymus: ${violations.length} violation(s) found across ${byFile.size} file(s).`
        );
        resolve();
      });
    });
  });
}

function mapSeverity(severity: string): vscode.DiagnosticSeverity {
  const config = vscode.workspace.getConfiguration('thymus');
  const map = config.get<Record<string, string>>('severityMap') ?? {};
  const mapped = map[severity];

  switch (mapped || severity) {
    case 'Error':
    case 'error':
      return vscode.DiagnosticSeverity.Error;
    case 'Warning':
    case 'warn':
    case 'warning':
      return vscode.DiagnosticSeverity.Warning;
    case 'Information':
    case 'info':
      return vscode.DiagnosticSeverity.Information;
    default:
      return vscode.DiagnosticSeverity.Warning;
  }
}

function updateStatusBar(): void {
  if (violationCount > 0) {
    statusBarItem.text = `$(alert) Thymus ${violationCount}`;
    statusBarItem.tooltip = `${violationCount} architectural violation(s). Click to scan workspace.`;
    statusBarItem.backgroundColor = new vscode.ThemeColor('statusBarItem.warningBackground');
  } else {
    statusBarItem.text = '$(check) Thymus';
    statusBarItem.tooltip = 'No architectural violations. Click to scan workspace.';
    statusBarItem.backgroundColor = undefined;
  }
}

export function deactivate(): void {
  if (debounceTimer) {
    clearTimeout(debounceTimer);
  }
}
