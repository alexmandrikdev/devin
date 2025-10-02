set -euo pipefail

base_branch="${args[--base]}"

validate_git_repository

date_stamp="$(date +%Y%m%d-%H%M%S)"
wip_branch="alexmandrik/wip/$date_stamp"

echo "👉 Pulling latest changes from $base_branch..."
git checkout "$base_branch" || {
    echo "❌ Failed to checkout $base_branch"
    exit 1
}
git pull origin "$base_branch" || {
    echo "❌ Failed to pull latest changes from $base_branch"
    exit 1
}

echo "👉 Creating WIP branch: $wip_branch"
git checkout -b "$wip_branch" || {
    echo "❌ Failed to create WIP branch"
    exit 1
}

echo "✅ WIP branch created: $wip_branch"
