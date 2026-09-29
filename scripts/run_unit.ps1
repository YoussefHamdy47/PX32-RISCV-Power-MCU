# PowerShell wrapper: runs scripts/run_unit.sh through Git Bash.
# Usage: scripts\run_unit.ps1 tb_px_alu [+vcd]
$bash = "C:\Program Files\Git\bin\bash.exe"
if (-not (Test-Path -LiteralPath $bash)) { throw "Git Bash not found: $bash" }
& $bash --noprofile --norc -c 'export PATH="/usr/bin:/bin:$PATH"; exec bash "$@"' -- "$PSScriptRoot/run_unit.sh" @args
exit $LASTEXITCODE
