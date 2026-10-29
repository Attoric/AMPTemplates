param(
    [Parameter(Mandatory = $true)][string]$GameIni,
    [string]$AmpIni = "",
    [int]$Keep = 10
)
$ErrorActionPreference = "Stop"
if (-not $AmpIni) { $AmpIni = "$GameIni.amp" }
$here = Split-Path -Parent $MyInvocation.MyCommand.Path
$py = Join-Path $here "beasts-of-bermuda-preserve-game-ini.py"
$pyCmd = Get-Command python3 -ErrorAction SilentlyContinue
if (-not $pyCmd) { $pyCmd = Get-Command py -ErrorAction SilentlyContinue }
if ($pyCmd -and (Test-Path $py)) {
    if ($pyCmd.Name -eq "py") {
        & $pyCmd.Source -3 $py --game-ini $GameIni --amp-ini $AmpIni --keep $Keep
    } else {
        & $pyCmd.Source $py --game-ini $GameIni --amp-ini $AmpIni --keep $Keep
    }
    exit $LASTEXITCODE
}
Write-Error "Install Python 3 to merge Game.ini, or run beasts-of-bermuda-preserve-game-ini.py"
exit 1
