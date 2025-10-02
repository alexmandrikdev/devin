set -euo pipefail

# Default values
BASE_BRANCH="${args[--base]}"

validate_git_repository

# Get current branch
CURRENT_BRANCH="$(git symbolic-ref --short HEAD)"

# Check if we're already on the base branch
if [ "$CURRENT_BRANCH" == "$BASE_BRANCH" ]; then
    echo "👉 Current branch is $BASE_BRANCH, exiting..."
    exit 0
fi

# Validate remote branch exists
if ! git ls-remote --exit-code origin "$BASE_BRANCH" > /dev/null 2>&1; then
    echo "❌ Remote branch origin/$BASE_BRANCH does not exist"
    exit 1
fi

# Get diff compared to base branch
echo "👉 Getting changes compared to origin/$BASE_BRANCH..."
diff=$(git diff "origin/$BASE_BRANCH".."$CURRENT_BRANCH" -- . \
    ':(exclude)package-lock.json' \
    ':(exclude)yarn.lock' \
    ':(exclude)pnpm-lock.yaml' \
    ':(exclude)composer.lock' \
    2>/dev/null | base64 -w 0) || {
    echo "❌ Failed to get diff compared to origin/$BASE_BRANCH"
    exit 1
}

# Check if there are actual changes
if [ -z "$diff" ] || [ "$diff" == "Cg==" ]; then
    echo "👉 No changes detected compared to origin/$BASE_BRANCH"
    exit 0
fi

# Get commit history
echo "👉 Getting commit history..."
commits=$(
    git log "origin/$BASE_BRANCH..HEAD" \
        --date=iso \
        --pretty=format:"Commit: %h%nDate: %ad%nSubject: %s%n%n%b%n---" \
    | base64 -w 0
) || {
    echo "❌ Failed to get commit history"
    exit 1
}

# Check if there are actual commits
if [ -z "$commits" ] || [ "$commits" == "Cg==" ]; then
    echo "👉 No commits detected compared to origin/$BASE_BRANCH"
    exit 0
fi

# Get repository path
repo_path=$(git rev-parse --show-toplevel)

# Prepare JSON payload
json_payload=$(jq -n \
    --arg changes "$diff" \
    --arg commits "$commits" \
    --arg repo_path "$repo_path" \
    '{
      "changes": $changes,
      "commits": $commits,
      "repo_path": $repo_path
    }') || {
    echo "❌ Failed to prepare JSON payload"
    exit 1
}

echo "👉 Calling webhook..."

# Make API call and capture both response and HTTP status code
response=$(curl -s -w "%{http_code}" -X POST \
    -H "Content-Type: application/json" \
    -d "$json_payload" \
    "$N8N_WEBHOOK_URL") || {
    echo "❌ Failed to call webhook"
    exit 1
}

# Extract HTTP status code and response body
http_code=${response: -3}
response_body=${response%???}

# Check HTTP status code
if [ "$http_code" -ne 200 ]; then
    echo "❌ Webhook returned HTTP $http_code"
    exit 1
fi

# Parse JSON response safely
if ! output=$(echo "$response_body" | jq -r '.output // empty'); then
    echo "❌ Failed to parse webhook response"
    exit 1
fi

if [ -z "$output" ]; then
    echo "❌ No output from webhook"
    exit 1
fi

# Decode and extract title and description
decoded_output=$(echo "$output" | base64 -d)

# Extract title
title=$(
    echo "$decoded_output" | 
    head -n 1 | 
    sed 's/^\*\*PR Title:\*\*//; s/^[[:space:]]*//; s/[[:space:]]*$//'
)

if [ -z "$title" ]; then
    echo "❌ Could not extract PR title from response"
    exit 1
fi

# Extract description
description=$(echo "$decoded_output" | tail -n +5)

if [ -z "$description" ]; then
    echo "❌ Could not extract PR description from response"
    exit 1
fi

# Display generated content
echo "📝 Title:"
echo "$title"
echo "---"
echo "📝 Description:"
echo "$description" | glow -
echo "---"

# Get user confirmation
echo -n "🤔 Accept PR? (y/n/e) "
read -r answer

case "$answer" in
    [yY]|yes)
        edit_pr=false
        ;;
    [eE]|edit)
        edit_pr=true
        ;;
    *)
        echo "👉 Exiting..."
        exit 0
        ;;
esac

# Push changes to remote
echo "👉 Pushing changes to $CURRENT_BRANCH..."
if ! git push origin "$CURRENT_BRANCH"; then
    echo "❌ Failed to push to $CURRENT_BRANCH"
    exit 1
fi

# Create pull request
echo "👉 Creating PR..."

if [ "$edit_pr" == "true" ]; then
    if ! gh pr create --title "$title" --body "$description" -e; then
        echo "❌ Failed to create PR"
        exit 1
    fi
else
    if ! gh pr create --title "$title" --body "$description"; then
        echo "❌ Failed to create PR"
        exit 1
    fi
fi

echo "✅ Done!"
