$ErrorActionPreference = "Stop"

$ProjectRoot = Split-Path -Parent $MyInvocation.MyCommand.Path
Set-Location $ProjectRoot

$SkillsRoot = ".agents\unreal-engine-skills\skills"
$ClaudeSkillsRoot = ".claude\skills"

if (-not (Test-Path -LiteralPath $SkillsRoot)) {
    throw "Cannot find $SkillsRoot. Please run this script from a project where the unreal-engine-skills submodule exists."
}

New-Item -ItemType Directory -Force -Path $ClaudeSkillsRoot | Out-Null

$Skills = @(
    "ue-project-context",
    "ue-data-assets-tables",
    "ue-ai-navigation",
    "ue-gameplay-abilities",
    "ue-networking-replication",
    "ue-cpp-foundations",
    "ue-actor-component-architecture",
    "ue-module-build-system"
)

foreach ($Skill in $Skills) {
    $Source = Join-Path $SkillsRoot $Skill
    $Destination = Join-Path $ClaudeSkillsRoot $Skill

    if (-not (Test-Path -LiteralPath $Source)) {
        Write-Warning "Missing source skill: $Source"
        continue
    }

    if (Test-Path -LiteralPath $Destination) {
        Write-Host "Already exists: $Destination"
        continue
    }

    New-Item -ItemType Junction -Path $Destination -Target $Source | Out-Null
    Write-Host "Linked: $Destination -> $Source"
}

Write-Host ""
Write-Host "Enabled Claude skills:"
Get-ChildItem -LiteralPath $ClaudeSkillsRoot
