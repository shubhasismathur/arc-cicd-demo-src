#!/usr/bin/env bash

# Parse input arguments
while getopts "s:d:r:b:i:t:e:p:" option; do
    case "$option" in
        s ) SOURCE_FOLDER=${OPTARG};;  # Source folder for manifests
        d ) DEST_FOLDER=${OPTARG};;    # Destination folder in the repo
        r ) DEST_REPO=${OPTARG};;      # Destination repository URL
        b ) DEST_BRANCH=${OPTARG};;    # Destination branch
        i ) DEPLOY_ID=${OPTARG};;      # Deployment ID
        t ) TOKEN=${OPTARG};;          # GitHub token
        e ) ENV_NAME=${OPTARG};;       # Environment name
    esac
done

# Debug: Print input parameters
echo "List input params"
echo "SOURCE_FOLDER: $SOURCE_FOLDER"
echo "DEST_FOLDER: $DEST_FOLDER"
echo "DEST_REPO: $DEST_REPO"
echo "DEST_BRANCH: $DEST_BRANCH"
echo "DEPLOY_ID: $DEPLOY_ID"
echo "ENV_NAME: $ENV_NAME"
echo "end of list"

set -euo pipefail  # Fail on error and undefined variables

# Git configuration
pr_user_name="Git Ops"
pr_user_email="agent@gitops.com"
git config --global user.email "$pr_user_email"
git config --global user.name "$pr_user_name"

# Prepare repository URL with token
repo_url="${DEST_REPO#http://}"
repo_url="${DEST_REPO#https://}"
repo_url="https://automated:$TOKEN@$repo_url"

# Always clone into a known directory to avoid directory name issues
CLONE_DIR="repo-clone-dir"

if git ls-remote --heads "$repo_url" "$DEST_BRANCH" | grep -q "$DEST_BRANCH"; then
    echo "Branch $DEST_BRANCH exists. Cloning..."
    git clone "$repo_url" -b "$DEST_BRANCH" --depth 1 --single-branch "$CLONE_DIR"
else
    echo "Branch $DEST_BRANCH does not exist. Cloning default branch and creating $DEST_BRANCH..."
    git clone "$repo_url" --depth 1 "$CLONE_DIR"
    cd "$CLONE_DIR"
    git checkout -b "$DEST_BRANCH"
    git push --set-upstream origin "$DEST_BRANCH"
    cd ..
fi

cd "$CLONE_DIR"

# Create a new deployment branch
deploy_branch_name="deploy/$DEPLOY_ID/$DEST_BRANCH"
echo "Create a new branch $deploy_branch_name"
git checkout -b "$deploy_branch_name"

# Add generated manifests to the new deploy branch
echo "Copying manifests from $SOURCE_FOLDER to $DEST_FOLDER"
mkdir -p "$DEST_FOLDER"
cp -r "$SOURCE_FOLDER"/* "$DEST_FOLDER/"

# Exclude templates/dev/azure-vote from commit if it exists
if [ -d "$DEST_FOLDER/templates/dev/azure-vote" ]; then
    echo "Excluding $DEST_FOLDER/templates/dev/azure-vote from commit"
    rm -rf "$DEST_FOLDER/templates/dev/azure-vote"
fi

git add -A
git status

# Commit and push changes if there are any
if [[ $(git status --porcelain | head -1) ]]; then
    echo "Committing changes"
    git commit -m "deployment $DEPLOY_ID"

    echo "Push to the deploy branch $deploy_branch_name"
    if ! git push --set-upstream "$repo_url" "$deploy_branch_name"; then
        echo "Push failed. Attempting to pull and rebase remote changes..."
        git fetch origin "$deploy_branch_name" || git fetch origin
        git rebase origin/"$deploy_branch_name" || {
            echo "Rebase failed. Please resolve conflicts manually.";
            exit 1;
        }
        git push --set-upstream "$repo_url" "$deploy_branch_name"
    fi

    # Create a pull request
    echo "Create a PR to $DEST_BRANCH"
    owner_repo="${DEST_REPO#https://github.com/}"
    echo "$owner_repo"
    echo "$TOKEN" | gh auth login --with-token
    gh pr create --base "$DEST_BRANCH" --head "$deploy_branch_name" --title "deployment '$DEPLOY_ID'" --body "Deploy to '$ENV_NAME'"
else
    echo "No changes to commit. Skipping PR creation."
fi