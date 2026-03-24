param(
    [Parameter(Mandatory = $true)]
    [string]$PromptFile,

    [string]$Model = "sonnet"
)

$ErrorActionPreference = "Stop"
$scriptDir = Split-Path -Parent $MyInvocation.MyCommand.Path
$root = Resolve-Path (Join-Path $scriptDir "..\..\..")
Set-Location $root

if (!(Test-Path $PromptFile)) {
    Write-Error "Prompt file not found: $PromptFile"
}

$promptText = Get-Content $PromptFile -Raw
if ([string]::IsNullOrWhiteSpace($promptText)) {
    Write-Error "Prompt file is empty: $PromptFile"
}

$timestamp = Get-Date -Format "yyyy-MM-dd_HH-mm-ss"
$promptName = [IO.Path]::GetFileNameWithoutExtension($PromptFile)
$runDir = Join-Path $root ".agent\teams\runs\$timestamp`__$promptName"
New-Item -ItemType Directory -Path $runDir -Force | Out-Null

$promptCopy = Join-Path $runDir "prompt.md"
$metaFile = Join-Path $runDir "meta.json"

Set-Content -Path $promptCopy -Value $promptText -Encoding UTF8
$promptHash = (Get-FileHash -Path $promptCopy -Algorithm SHA256).Hash

$meta = [ordered]@{
    timestamp = (Get-Date).ToString("o")
    model = $Model
    promptFile = (Resolve-Path $PromptFile).Path
    promptHashSha256 = $promptHash
    mode = "interactive"
    cwd = (Get-Location).Path
}
$meta | ConvertTo-Json -Depth 5 | Set-Content -Path $metaFile -Encoding UTF8

Set-Clipboard -Value $promptText
Write-Host "Run directory: $runDir"
Write-Host "Prompt hash: $promptHash"
Write-Host "Prompt copied to clipboard."
Write-Host "When Claude opens: paste prompt and press Enter."

claude --model $Model
exit $LASTEXITCODE
