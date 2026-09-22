# Dot-source only in a child process or use Invoke-BonsaiClaude.ps1.
# Never replace the user's cloud settings globally.
$env:ANTHROPIC_BASE_URL = 'http://127.0.0.1:8080'
$env:ANTHROPIC_AUTH_TOKEN = 'local-only'
$env:ANTHROPIC_MODEL = 'bonsai2-27b'

