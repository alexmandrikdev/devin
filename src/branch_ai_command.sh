set -euo pipefail

BASE_BRANCH="${args[--base]}"
THINKING_FLAG="${args[--thinking]:-false}"

validate_git_repository

# Get current branch
CURRENT_BRANCH="$(git symbolic-ref --short HEAD)"

# Check if we're already on the base branch
if [ "$CURRENT_BRANCH" == "$BASE_BRANCH" ]; then
    echo "👉 Current branch is $BASE_BRANCH, exiting..."
    exit 0
fi

# Rebase current branch onto base branch
echo "👉 Rebasing $CURRENT_BRANCH onto $BASE_BRANCH..."
git checkout "$BASE_BRANCH"
git pull
git checkout "$CURRENT_BRANCH"
git rebase "$BASE_BRANCH"

# Get commit history
echo "👉 Getting commit history..."
commits=$(
    git log "$BASE_BRANCH..HEAD" \
        --date=iso \
        --reverse \
        --pretty=format:"Commit: %h%nDate: %ad%nSubject: %s%n%n%b%n---" \
    | base64 -w 0
) || {
    echo "❌ Failed to get commit history"
    exit 1
}

# Check if there are actual commits
if [ -z "$commits" ] || [ "$commits" == "Cg==" ]; then
    echo "👉 No commits detected compared to $BASE_BRANCH"
    exit 0
fi

# Get repository path
repo_path=$(git rev-parse --show-toplevel)

# Prepare JSON payload
json_payload=$(jq -n \
    --arg commits "$commits" \
    --arg repo_path "$repo_path" \
    --argjson thinking "$THINKING_FLAG" \
    '{
      "commits": $commits,
      "repo_path": $repo_path,
      "thinking": $thinking
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

# Remove markdown code blocks
output=$(echo "$output" | base64 --decode | sed '/^```/d')

# Validate JSON array
if ! echo "$output" | jq -e '. | type == "array"' >/dev/null 2>&1; then
    echo "❌ Invalid JSON array format"
    exit 1
fi

echo "👉 Processing output..."

git checkout "$BASE_BRANCH"

# Process each item in the array
while IFS= read -r -u 3 item; do
    if [ -n "$item" ]; then
        name=$(echo "$item" | jq -r '.name // empty')

        if [ -z "$name" ]; then
            echo "❌ Invalid item format"
            exit 1
        fi
        
        echo -e "\n---\n"
        echo "Branch: $name"
        echo "Commits:"
        
        while IFS= read -r commit; do
            echo $(git show -s --format="%h %s" "$commit")
        done < <(echo "$item" | jq -r '.commits[]')
        
        # Get user confirmation
        echo -n "🤔 Accept this branch name for these commits? (y/n) "
        read -r answer

        case "$answer" in
            [yY]|yes)
                echo "✅ Creating branch: $name"
                git checkout -b "$name"

                while IFS= read -r commit; do
                    echo "🍒 Cherry-picking: $commit"
                    git cherry-pick "$commit"
                done < <(echo "$item" | jq -r '.commits[]')
                ;;
            *)
                echo "👉 Exiting..."
                exit 0
                ;;
        esac
    fi
done 3< <(echo "$output" | jq -c '.[]')

echo "👉 Done!"