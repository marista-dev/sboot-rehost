# ensure_inbox.ps1 - SessionStart hook. Creates the firmware inbox in the user's
# project dir (only if missing). ASCII-only source (Windows PowerShell 5 reads .ps1
# as ANSI without a BOM). Silent; never blocks the session.
try {
  if (-not $env:CLAUDE_PROJECT_DIR) { exit 0 }
  $inbox = Join-Path (Join-Path $env:CLAUDE_PROJECT_DIR 'rehost_workspaces') '_inbox'
  if (-not (Test-Path -LiteralPath $inbox)) {
    New-Item -ItemType Directory -Force -Path $inbox | Out-Null
    $src = Join-Path $env:CLAUDE_PLUGIN_ROOT 'scripts/inbox_readme.txt'
    $dst = Join-Path $inbox 'DROP_FIRMWARE_HERE.txt'
    if ($env:CLAUDE_PLUGIN_ROOT -and (Test-Path -LiteralPath $src)) {
      Copy-Item -LiteralPath $src -Destination $dst -Force
    }
  }
} catch { }
exit 0
