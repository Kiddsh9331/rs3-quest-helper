# Copies the test plugin into the RuneScape beta client's dev_plugins folder.
# Re-run after every change, then `prl rs3-quest-buddy` in the game console.
param(
    [string]$BetaRoot = "C:\ProgramData\Jagex\RuneScape-BETA"
)

if (-not (Test-Path $BetaRoot)) {
    Write-Error "No beta client at $BetaRoot. Join the plugin beta once (developer.runescape.com, 'Accessing the API'), or pass -BetaRoot with your cache folder."
    exit 1
}

$source = Join-Path $PSScriptRoot "rs3-quest-buddy"
$target = Join-Path $BetaRoot "dev_plugins\rs3-quest-buddy"
# The test build's folder before the rename: remove it so the game doesn't
# load the plugin twice.
$old = Join-Path $BetaRoot "dev_plugins\rs3qh-test"
if (Test-Path $old) {
    Remove-Item -Recurse -Force $old
    Write-Output "Removed the old copy at $old"
}
New-Item -ItemType Directory -Force $target | Out-Null
Copy-Item -Path (Join-Path $source "*") -Destination $target -Recurse -Force
Write-Output "Installed to $target"
