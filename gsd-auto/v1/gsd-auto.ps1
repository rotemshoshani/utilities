<#
.SYNOPSIS
    Automated GSD runner. Plans and executes phases with fresh context per plan.

.DESCRIPTION
    For each phase in the given range:
      1. Plans the phase (if not already planned)
      2. Executes each plan individually via `claude -p` (fresh context = free /clear)
      3. Skips already-completed plans (SUMMARY.md exists)
      4. Pauses for human input when checkpoints or verification is needed
      5. Sends Windows toast notification when paused or done

.EXAMPLE
    .\gsd-auto.ps1 47 48                              # Phases 47-48 in current dir
    .\gsd-auto.ps1 46 46                               # Finish phase 46 (skips completed plans)
    .\gsd-auto.ps1 47 48 -DryRun                       # Preview what would run
    .\gsd-auto.ps1 47 48 -ProjectDir "C:\my\project"   # Explicit project path
    .\gsd-auto.ps1 47 48 -Push                            # Auto commit + push when done

.NOTES
    Requires: claude CLI in PATH, GSD framework installed
    Uses --dangerously-skip-permissions for non-interactive execution
#>

param(
    [Parameter(Mandatory, Position = 0)]
    [int]$StartPhase,

    [Parameter(Mandatory, Position = 1)]
    [int]$EndPhase,

    # Path to the GSD project root (must contain .planning/phases/)
    # Defaults to the current working directory
    [string]$ProjectDir = (Get-Location).Path,

    # Preview mode — shows what would run without executing
    [switch]$DryRun,

    # Auto commit and push all changes when the run finishes
    [switch]$Push
)

$ErrorActionPreference = "Stop"
$PhasesDir = Join-Path $ProjectDir ".planning\phases"
$LogDir = Join-Path $ProjectDir ".planning\logs\auto"
$StopFile = Join-Path $ProjectDir ".planning\STOP"

# Validate project structure
if (-not (Test-Path $PhasesDir)) {
    Write-Host "  ERROR: No .planning/phases/ directory found at $ProjectDir" -ForegroundColor Red
    Write-Host "  Make sure you're in a GSD project root or pass -ProjectDir" -ForegroundColor Yellow
    exit 1
}

# Patterns in claude output that mean "stop and get human"
# These come from GSD's checkpoint and verification systems
$HumanStopPatterns = @(
    "CHECKPOINT REACHED",
    "CHECKPOINT: Verification Required",
    "CHECKPOINT: Action Required",
    "CHECKPOINT: Decision Required",
    "YOUR ACTION:",
    "human_needed",
    "gaps_found"
)

# Patterns that indicate API rate limiting — must stop immediately
$RateLimitPatterns = @(
    "You.ve hit your limit",
    "rate limit",
    "Too many requests",
    "429"
)

# -- Sleep prevention ---------------------------------------------------------

Add-Type -TypeDefinition @"
using System;
using System.Runtime.InteropServices;
public static class SleepPrevention {
    [DllImport("kernel32.dll", SetLastError = true)]
    private static extern uint SetThreadExecutionState(uint esFlags);

    private const uint ES_CONTINUOUS       = 0x80000000;
    private const uint ES_SYSTEM_REQUIRED  = 0x00000001;

    public static void PreventSleep() {
        SetThreadExecutionState(ES_CONTINUOUS | ES_SYSTEM_REQUIRED);
    }

    public static void AllowSleep() {
        SetThreadExecutionState(ES_CONTINUOUS);
    }
}
"@

# -- Helpers ------------------------------------------------------------------

function Send-Toast([string]$Title, [string]$Message) {
    try {
        [Windows.UI.Notifications.ToastNotificationManager, Windows.UI.Notifications, ContentType = WindowsRuntime] > $null
        $tmpl = [Windows.UI.Notifications.ToastNotificationManager]::GetTemplateContent(
            [Windows.UI.Notifications.ToastTemplateType]::ToastText02
        )
        $tmpl.GetElementsByTagName('text').Item(0).AppendChild($tmpl.CreateTextNode($Title)) > $null
        $tmpl.GetElementsByTagName('text').Item(1).AppendChild($tmpl.CreateTextNode($Message)) > $null
        $notif = [Windows.UI.Notifications.ToastNotification]::new($tmpl)
        [Windows.UI.Notifications.ToastNotificationManager]::CreateToastNotifier("GSD Auto").Show($notif)
    } catch { }
}

function Invoke-Claude([string]$Prompt, [string]$StepLabel) {
    $logFile = Join-Path $LogDir "$StepLabel-$(Get-Date -Format 'HHmmss').log"

    Push-Location $ProjectDir
    try {
        $output = & claude -p $Prompt --dangerously-skip-permissions --model opus 2>&1 | Out-String
        $code = $LASTEXITCODE
    } finally {
        Pop-Location
    }

    if (-not (Test-Path (Split-Path $logFile))) { New-Item -ItemType Directory -Path (Split-Path $logFile) -Force | Out-Null }
    $output | Out-File -FilePath $logFile -Encoding utf8
    Write-Host "    Log: $logFile" -ForegroundColor DarkGray

    return @{ Output = $output; ExitCode = $code; LogFile = $logFile }
}

function Test-NeedsHuman([string]$Output) {
    foreach ($pattern in $HumanStopPatterns) {
        if ($Output -match [regex]::Escape($pattern)) {
            return $pattern
        }
    }
    return $null
}

function Test-RateLimit([string]$Output) {
    foreach ($pattern in $RateLimitPatterns) {
        if ($Output -match [regex]::Escape($pattern)) {
            return $true
        }
    }
    return $false
}

function Test-StopRequested {
    if (Test-Path $StopFile) {
        Remove-Item $StopFile -Force
        return $true
    }
    return $false
}

function Get-PhaseDir([int]$PhaseNum) {
    $dirs = @(Get-ChildItem $PhasesDir -Directory | Where-Object { $_.Name -match "^0*$PhaseNum-" })
    if ($dirs.Count -eq 0) { return $null }
    if ($dirs.Count -eq 1) { return $dirs[0] }

    # Multiple matches — prefer the one that already has PLAN files
    $withPlans = @($dirs | Where-Object {
        (Get-ChildItem $_.FullName -Filter "*-PLAN.md" -ErrorAction SilentlyContinue).Count -gt 0
    })
    if ($withPlans.Count -gt 0) { return $withPlans[0] }

    # No plans yet in any dir — return the last one (most specific/recent name)
    return ($dirs | Select-Object -Last 1)
}

function Get-PlanFiles([string]$PhaseDirPath) {
    return Get-ChildItem $PhaseDirPath -Filter "*-PLAN.md" -ErrorAction SilentlyContinue |
        Sort-Object Name
}

function Test-PlanComplete([string]$PhaseDirPath, [string]$PlanFileName) {
    $summaryName = $PlanFileName -replace '-PLAN\.md$', '-SUMMARY.md'
    return Test-Path (Join-Path $PhaseDirPath $summaryName)
}

function Get-RelativePath([string]$FullPath) {
    return $FullPath.Replace("$ProjectDir\", "").Replace("\", "/")
}

function Test-PlanHasCheckpoint([string]$PlanPath) {
    # Read frontmatter and check for autonomous: false
    $inFrontmatter = $false
    foreach ($line in Get-Content $PlanPath -TotalCount 20) {
        if ($line -match '^---\s*$') {
            if ($inFrontmatter) { break }  # End of frontmatter
            $inFrontmatter = $true
            continue
        }
        if ($inFrontmatter -and $line -match '^\s*autonomous:\s*false') {
            return $true
        }
    }
    return $false
}

# -- Main ---------------------------------------------------------------------

if (-not (Test-Path $LogDir)) { New-Item -ItemType Directory -Path $LogDir -Force | Out-Null }

$totalSteps = 0
$startTime = Get-Date

Write-Host ""
Write-Host "  GSD Auto-Runner" -ForegroundColor Cyan
Write-Host "  ===============" -ForegroundColor Cyan
Write-Host "  Phases:   $StartPhase -> $EndPhase" -ForegroundColor White
Write-Host "  Model:    opus" -ForegroundColor White
Write-Host "  Project:  $ProjectDir" -ForegroundColor DarkGray
if ($DryRun) { Write-Host "  MODE:     DRY RUN" -ForegroundColor Yellow }
if ($Push) { Write-Host "  Push:     ON (will commit + push when done)" -ForegroundColor White }
Write-Host "  Stop:     echo stop > .planning\STOP  (from project root)" -ForegroundColor DarkGray
Write-Host ""

$stopped = $false

# Keep system awake for the entire run
[SleepPrevention]::PreventSleep()
Write-Host "  Sleep prevention: ON" -ForegroundColor DarkGray
Write-Host ""

try {

for ($phase = $StartPhase; $phase -le $EndPhase; $phase++) {
    if ($stopped) { break }

    # Check for graceful stop signal
    if (Test-StopRequested) {
        Write-Host ""
        Write-Host "  Stop signal detected (.planning/STOP). Halting before phase $phase." -ForegroundColor Yellow
        Send-Toast "GSD Auto - Stopped" "Stop signal received before phase $phase"
        $stopped = $true
        break
    }

    Write-Host "===========================================================" -ForegroundColor Cyan
    Write-Host "  PHASE $phase" -ForegroundColor Cyan
    Write-Host "===========================================================" -ForegroundColor Cyan

    # -- Find phase directory --------------------------------------------------
    $phaseDir = Get-PhaseDir $phase
    if (-not $phaseDir) {
        Write-Host "  ERROR: No directory found for phase $phase in $PhasesDir" -ForegroundColor Red
        $stopped = $true
        break
    }
    Write-Host "  Dir: $($phaseDir.Name)" -ForegroundColor DarkGray

    # -- Plan phase if needed --------------------------------------------------
    $planFiles = Get-PlanFiles $phaseDir.FullName
    $needsPlanning = (-not $planFiles -or $planFiles.Count -eq 0)

    # If plans exist but NONE have been executed (no summaries), the previous run
    # planned but never got to execute (e.g. rate limited). Re-plan for fresh context.
    if (-not $needsPlanning -and $planFiles) {
        $hasAnySummary = $false
        foreach ($pf in $planFiles) {
            if (Test-PlanComplete $phaseDir.FullName $pf.Name) {
                $hasAnySummary = $true
                break
            }
        }
        if (-not $hasAnySummary) {
            Write-Host "  Plans exist but none executed - re-planning for fresh context" -ForegroundColor Yellow
            foreach ($pf in $planFiles) { Remove-Item $pf.FullName -Force }
            $planFiles = $null
            $needsPlanning = $true
        }
    }

    if ($needsPlanning) {
        $totalSteps++
        $timestamp = Get-Date -Format "HH:mm:ss"
        Write-Host ""
        Write-Host "  [$totalSteps] $timestamp  Planning phase $phase..." -ForegroundColor Green
        Write-Host "    /gsd:plan-phase $phase" -ForegroundColor Cyan

        if ($DryRun) {
            Write-Host "    [DRY RUN] Would run: claude -p '/gsd:plan-phase $phase'" -ForegroundColor Yellow
            continue
        }

        $result = Invoke-Claude "/gsd:plan-phase $phase" "phase$phase-plan"

        # Check for rate limits — but only stop if planning didn't actually produce plans
        if (Test-RateLimit $result.Output) {
            $checkDir = Get-PhaseDir $phase
            $checkPlans = if ($checkDir) { Get-PlanFiles $checkDir.FullName } else { @() }
            if ($checkPlans.Count -gt 0) {
                Write-Host "    Rate limit hit, but plan files exist — planning completed successfully." -ForegroundColor Yellow
            } else {
                Write-Host "    RATE LIMITED - planning phase $phase hit API limit" -ForegroundColor Red
                Write-Host "    Wait for rate limit to reset, then re-run." -ForegroundColor Yellow
                Send-Toast "GSD Auto - Rate Limited" "API limit hit during planning phase $phase"
                $stopped = $true
                break
            }
        }

        if ($result.ExitCode -and $result.ExitCode -ne 0) {
            Write-Host "    ERROR: plan-phase exited with code $($result.ExitCode)" -ForegroundColor Red
            Send-Toast "GSD Auto - Error" "plan-phase $phase failed"
            $stopped = $true
            break
        }

        # Check if planning itself needs human input
        $humanMatch = Test-NeedsHuman $result.Output
        if ($humanMatch) {
            Write-Host ""
            Write-Host "    HUMAN INPUT NEEDED (matched: $humanMatch)" -ForegroundColor Red
            Write-Host "    Check log for details: $($result.LogFile)" -ForegroundColor Yellow
            Send-Toast "GSD Auto - Paused" "Phase $phase planning needs human input"
            Write-Host ""
            $response = Read-Host "    Press Enter to continue, or type 'stop' to abort"
            if ($response -eq 'stop') { $stopped = $true; break }
        }

        # Re-resolve phase dir (planning may have created a new directory)
        $phaseDir = Get-PhaseDir $phase
        $planFiles = Get-PlanFiles $phaseDir.FullName
        if (-not $planFiles -or $planFiles.Count -eq 0) {
            Write-Host "    ERROR: No PLAN files found after planning phase $phase" -ForegroundColor Red
            $stopped = $true
            break
        }
    }

    $planCount = @($planFiles).Count
    Write-Host "  Plans: $planCount" -ForegroundColor White

    # -- Execute each plan -----------------------------------------------------
    $planIndex = 0
    foreach ($plan in $planFiles) {
        if ($stopped) { break }
        $planIndex++

        # Check for graceful stop signal
        if (Test-StopRequested) {
            Write-Host ""
            Write-Host "    Stop signal detected (.planning/STOP). Halting before $($plan.Name)." -ForegroundColor Yellow
            Send-Toast "GSD Auto - Stopped" "Stop signal received before $($plan.Name)"
            $stopped = $true
            break
        }

        # Skip completed plans
        if (Test-PlanComplete $phaseDir.FullName $plan.Name) {
            Write-Host ""
            Write-Host "  [$planIndex/$planCount] SKIP $($plan.Name) (already complete)" -ForegroundColor DarkGray
            continue
        }

        $totalSteps++
        $timestamp = Get-Date -Format "HH:mm:ss"
        $relativePath = Get-RelativePath $plan.FullName

        # Check if plan has checkpoints (autonomous: false) — must run interactively
        if (Test-PlanHasCheckpoint $plan.FullName) {
            Write-Host ""
            Write-Host "  [$planIndex/$planCount] $timestamp  $($plan.Name) requires human verification" -ForegroundColor Yellow
            Write-Host ""
            Write-Host "    This plan has a checkpoint that needs interactive execution." -ForegroundColor Yellow
            Write-Host "    Run it in a Claude Code instance:" -ForegroundColor White
            Write-Host ""
            Write-Host "    /gsd:execute-plan $relativePath" -ForegroundColor Cyan
            Write-Host ""
            Write-Host "    Then re-run gsd-auto to continue from where it left off." -ForegroundColor White
            Send-Toast "GSD Auto - Interactive Plan" "$($plan.Name) needs interactive execution"
            $stopped = $true
            break
        }

        Write-Host ""
        Write-Host "  [$planIndex/$planCount] $timestamp  Executing $($plan.Name)..." -ForegroundColor Green
        Write-Host "    /gsd:execute-plan $relativePath" -ForegroundColor Cyan

        if ($DryRun) {
            Write-Host "    [DRY RUN] Would run: claude -p '/gsd:execute-plan $relativePath'" -ForegroundColor Yellow
            continue
        }

        $result = Invoke-Claude "/gsd:execute-plan $relativePath" "phase$phase-$($plan.BaseName)"

        # Check for rate limits — but only stop if the plan didn't actually complete
        if (Test-RateLimit $result.Output) {
            if (Test-PlanComplete $phaseDir.FullName $plan.Name) {
                Write-Host "    Rate limit hit, but SUMMARY.md exists — plan completed successfully." -ForegroundColor Yellow
            } else {
                Write-Host "    RATE LIMITED - execution hit API limit" -ForegroundColor Red
                Write-Host "    Wait for rate limit to reset, then re-run." -ForegroundColor Yellow
                Write-Host "    Will resume from $($plan.Name)." -ForegroundColor Yellow
                Send-Toast "GSD Auto - Rate Limited" "API limit hit during $($plan.Name)"
                $stopped = $true
                break
            }
        }

        if ($result.ExitCode -and $result.ExitCode -ne 0) {
            Write-Host "    ERROR: execute-plan exited with code $($result.ExitCode)" -ForegroundColor Red
            Write-Host "    Check log: $($result.LogFile)" -ForegroundColor Yellow
            Send-Toast "GSD Auto - Error" "$($plan.Name) failed"
            $stopped = $true
            break
        }

        # Check for human verification/checkpoints in output
        $humanMatch = Test-NeedsHuman $result.Output
        if ($humanMatch) {
            Write-Host ""
            Write-Host "    HUMAN INPUT NEEDED (matched: $humanMatch)" -ForegroundColor Red
            Write-Host "    Check log for details: $($result.LogFile)" -ForegroundColor Yellow
            Send-Toast "GSD Auto - Paused" "$($plan.Name) needs human input"
            Write-Host ""
            $response = Read-Host "    Press Enter to continue, or type 'stop' to abort"
            if ($response -eq 'stop') { $stopped = $true; break }
        }

        # Verify the plan actually completed (SUMMARY.md should exist now)
        if (-not (Test-PlanComplete $phaseDir.FullName $plan.Name)) {
            Write-Host "    WARNING: No SUMMARY.md found after execution" -ForegroundColor Yellow
            Write-Host "    The plan may not have completed successfully" -ForegroundColor Yellow
            Write-Host "    Check log: $($result.LogFile)" -ForegroundColor Yellow
            Send-Toast "GSD Auto - Warning" "$($plan.Name) may not have completed"
            Write-Host ""
            $response = Read-Host "    Press Enter to continue anyway, or type 'stop' to abort"
            if ($response -eq 'stop') { $stopped = $true; break }
        } else {
            Write-Host "    Done. SUMMARY.md created." -ForegroundColor Green
        }
    }

    if (-not $stopped) {
        Write-Host ""
        Write-Host "  Phase $phase complete!" -ForegroundColor Green
    }
}

# -- Summary -------------------------------------------------------------------

} finally {
    [SleepPrevention]::AllowSleep()
    Write-Host ""
    Write-Host "  Sleep prevention: OFF" -ForegroundColor DarkGray
}

$elapsed = (Get-Date) - $startTime

Write-Host ""
Write-Host "===========================================================" -ForegroundColor Cyan
if ($stopped) {
    Write-Host "  Stopped after $totalSteps steps ($($elapsed.ToString('hh\:mm\:ss')))" -ForegroundColor Yellow
} else {
    Write-Host "  All done! $totalSteps steps in $($elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
}
Write-Host "  Logs: $LogDir" -ForegroundColor DarkGray
Write-Host "===========================================================" -ForegroundColor Cyan
Write-Host ""

Send-Toast "GSD Auto - Finished" "$totalSteps steps in $($elapsed.ToString('hh\:mm\:ss'))"

# -- Auto commit + push --------------------------------------------------------

if ($Push -and -not $DryRun -and $totalSteps -gt 0) {
    Push-Location $ProjectDir
    try {
        # Check if there are any changes to commit
        $status = & git status --porcelain 2>&1
        if ($status) {
            $msg = "GSD Auto: phases $StartPhase-$EndPhase ($totalSteps steps)"
            Write-Host ""
            Write-Host "  Committing and pushing..." -ForegroundColor Cyan
            & git add -A
            & git commit -m $msg
            & git push
            if ($LASTEXITCODE -eq 0) {
                Write-Host "  Pushed successfully." -ForegroundColor Green
            } else {
                Write-Host "  Push failed (exit code $LASTEXITCODE)" -ForegroundColor Red
                Send-Toast "GSD Auto - Push Failed" "git push failed"
            }
        } else {
            Write-Host ""
            Write-Host "  No changes to commit." -ForegroundColor DarkGray
        }
    } finally {
        Pop-Location
    }
}
