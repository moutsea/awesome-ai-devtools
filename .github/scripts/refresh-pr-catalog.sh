#!/usr/bin/env bash
set -euo pipefail

pr_head=$1
base=$(git rev-parse HEAD)
generated=(README.md docs/COMPARISON.md)
temp_dir=$(mktemp -d)
trap 'rm -rf -- "$temp_dir"' EXIT

# Merge Git objects in a temporary index. Only the catalog YAML enters the trusted checkout.
merge_status=0
git merge-tree --write-tree --name-only -z "$pr_head" "$base" > "$temp_dir/merge" || merge_status=$?
if (( merge_status > 1 )); then
  echo 'Git could not merge the PR and the default branch.' >&2
  exit 1
fi
{
  IFS= read -r -d '' merged_tree
  if (( merge_status == 1 )); then
    # The path list ends at the empty field. Conflict records also cover renames and other structural conflicts.
    while IFS= read -r -d '' path && [[ -n "$path" ]]; do
      case "$path" in
        README.md|docs/COMPARISON.md) ;;
        *) printf 'Resolve the merge conflict in %q before refreshing the catalog.\n' "$path" >&2; exit 1 ;;
      esac
    done
    resolved=false
    while IFS= read -r -d '' count; do
      paths=()
      for (( i=0; i<count; i++ )); do
        IFS= read -r -d '' path
        paths+=("$path")
      done
      IFS= read -r -d '' kind
      IFS= read -r -d '' # Skip the human-readable detail.
      case "$kind" in
        Auto-merging) continue ;;
        'CONFLICT (contents)'|'CONFLICT (modify/delete)')
          if (( count == 1 )) && [[ ${paths[0]} == README.md || ${paths[0]} == docs/COMPARISON.md ]]; then
            resolved=true
            continue
          fi ;;
      esac
      printf 'Resolve %s before refreshing the catalog. Affected paths:' "$kind" >&2
      printf ' %q' "${paths[@]}" >&2
      printf '\n' >&2
      exit 1
    done
    if [[ "$resolved" == false ]]; then
      echo 'Git reported a conflict without identifying a generated file to resolve.' >&2
      exit 1
    fi
  fi
} < "$temp_dir/merge"

if ! git diff --quiet --no-ext-diff --no-textconv "$base" "$merged_tree" -- scripts package.json package-lock.json tsconfig.json; then
  echo 'This PR changes catalog tooling. Regenerate with the PR tooling after reviewing it.' >&2
  exit 1
fi

for path in data/tools.yml data/categories.yml data/tags.yml; do
  if [[ $(git ls-tree "$merged_tree" -- "$path") != '100644 blob '* ]]; then
    printf 'Expected a regular catalog file at %s.\n' "$path" >&2
    exit 1
  fi
  git show "$merged_tree:$path" > "$path"
done

npm ci --ignore-scripts --no-audit --no-fund
npm run sort
npm run generate
npm run validate

export GIT_INDEX_FILE="$temp_dir/index"
git read-tree "$merged_tree"
for path in data/tools.yml "${generated[@]}"; do
  blob=$(git hash-object -w --no-filters -- "$path")
  git update-index --add --cacheinfo "100644,$blob,$path"
done
tree=$(git write-tree)
parents=(-p "$pr_head")
message='Regenerate PR catalog'
if ! git merge-base --is-ancestor "$base" "$pr_head"; then
  parents+=(-p "$base")
  message='Merge default branch and regenerate PR catalog'
elif [[ "$tree" == "$(git rev-parse "$pr_head^{tree}")" ]]; then
  echo 'The PR already contains the default branch and current catalog output.'
  exit 0
fi

commit=$(git -c user.name='github-actions[bot]' -c user.email='41898282+github-actions[bot]@users.noreply.github.com' \
  commit-tree "$tree" "${parents[@]}" -m "$message")
echo "commit=$commit" >> "$GITHUB_OUTPUT"
