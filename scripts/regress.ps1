# PowerShell wrapper: runs scripts/regress.sh through Git Bash.
$bash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path -LiteralPath $bash)) { throw "Git Bash not found: $bash" }
& $bash --noprofile --norc -c 'export PATH="/usr/bin:/bin:$PATH"; exec bash "$@"' -- "$PSScriptRoot/regress.sh" @args
exit $LASTEXITCODE
