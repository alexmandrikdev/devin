set -euo pipefail

description=${args[description]:-} 

validate_git_repository

get_staged_changes() {
    git diff --staged -- . \
        ':(exclude)package-lock.json' \
        ':(exclude)yarn.lock' \
        ':(exclude)pnpm-lock.yaml' \
        ':(exclude)composer.lock' 2>/dev/null | base64 --wrap=0 || {
        echo "❌ Failed to get diff"
        exit 1
    }
}

echo "👉 Getting staged changes..."
diff="$(get_staged_changes)"

# Check if there are actual changes
if [ -z "$diff" ] || [ "$diff" == "Cg==" ]; then
    echo -n "🤔 No staged changes found. Do you want to commit all changes? (y/n) "
    read -r answer

    if [[ "$answer" != "y" && "$answer" != "Y" && "$answer" != "yes" ]]; then
        echo "👉 Exiting..."
        exit 0
    fi

    echo "👉 Committing all changes..."
    git add .
    diff="$(get_staged_changes)"
fi

repo_path=$(git rev-parse --show-toplevel)

json_payload=$(jq -n \
    --arg changes "$diff" \
    --arg description "$description" \
    --arg repo_path "$repo_path" \
    '{
      "changes": $changes,
      "description": $description,
      "repo_path": $repo_path
    }')

echo "👉 Calling webhook..."

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

commit_message=$(echo "$output" | base64 --decode)

if [ -z "$commit_message" ]; then
    echo "❌ No commit message from webhook"
    exit 1
fi

echo "💬 Commit message:"
echo "$commit_message"

echo -n "🤔 Accept commit message? (y/n/e) "
read -r answer

case "$answer" in
    [yY]|yes)
        edit_message=false
        ;;
    [eE]|edit)
        edit_message=true
        ;;
    *)
        echo "👉 Exiting..."
        exit 0
        ;;
esac

echo "👉 Committing changes..."
if [ "$edit_message" = true ]; then
    git commit -e -m "$commit_message" || {
        echo "❌ Failed to commit changes"
        exit 1
    }
else
    git commit -m "$commit_message" || {
        echo "❌ Failed to commit changes"
        exit 1
    }
fi

echo "✅ Done"