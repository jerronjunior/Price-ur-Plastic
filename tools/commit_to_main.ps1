param(
    [string]$Message = "Auto-commit",
    [switch]$DeleteBranch
)

function Run-Git([string]$args) {
    Write-Host "git $args"
    git $args
    if ($LASTEXITCODE -ne 0) {
        Write-Error "Command failed: git $args"
        exit $LASTEXITCODE
    }
}

# Determine current branch
$cur = git rev-parse --abbrev-ref HEAD
if ($LASTEXITCODE -ne 0) { Write-Error "Not a git repository"; exit 1 }

# Stage all changes
Write-Host "Staging changes..."
Run-Git "add -A"

# Commit
Write-Host "Committing: $Message"
# If no changes, git commit exits 1 — capture and continue
git commit -m "$Message"
$commitCode = $LASTEXITCODE
if ($commitCode -ne 0) {
    Write-Host "No changes to commit or commit failed (exit $commitCode). Continuing..."
}

if ($cur -eq 'main') {
    Write-Host "On main: pulling and pushing"
    Run-Git "pull origin main"
    Run-Git "push origin main"
    exit 0
}

# Ensure current branch commits pushed
Write-Host "Pushing feature branch $cur"
Run-Git "push origin $cur"

# Merge into main
Write-Host "Merging $cur into main"
Run-Git "checkout main"
Run-Git "pull origin main"
Run-Git "merge --no-ff $cur -m \"Merge $cur into main: $Message\""
Run-Git "push origin main"

# Optionally delete branch
if ($DeleteBranch) {
    Write-Host "Deleting branch $cur locally and remotely"
    git branch -D $cur
    git push origin --delete $cur
}

# Return to original branch
Write-Host "Checking out original branch $cur"
Run-Git "checkout $cur"
Write-Host "Done. Changes merged to main."
