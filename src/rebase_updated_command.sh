set -euo pipefail

base_branch="${args[--base]}"

validate_git_repository

current_branch="$(git symbolic-ref --short HEAD)"

git checkout "$base_branch" || {
    echo "❌ Failed to checkout $base_branch"
    exit 1
}
git pull origin "$base_branch" || {
    echo "❌ Failed to pull latest changes from $base_branch"
    exit 1
}

git checkout "$current_branch" || {
    echo "❌ Failed to checkout $current_branch"
    exit 1
}
git rebase "$base_branch" || {
    echo "❌ Failed to rebase $current_branch onto $base_branch"
    exit 1
}

echo "✅ Rebased $current_branch onto $base_branch"